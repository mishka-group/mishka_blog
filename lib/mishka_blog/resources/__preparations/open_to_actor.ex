# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Preparations.OpenToActor do
  @moduledoc """
  Keeps a public read to the records its reader may open, by the rule the record's page keeps: a
  record whose lock names permissions opens only for a reader holding one of them
  (`AccessPermissions.match?/3`), and never for a visitor who is not signed in. A list leaves out,
  in its own query, every record the reader may not open, so its pages and its count are of what
  the reader sees; asking for one of them by itself finds nothing, as an id nothing is stored at
  does.

      prepare {OpenToActor, kind: :post}

  THE READER is the actor of an authorized read: the visitor a page reads for, as the blog's
  components pass it — `nil` for a visitor who is not signed in — and the JSON:API's caller.

      Ash.Query.for_read(MishkaBlog.BlogPost, :public_list, %{},
        actor: current_user,
        tenant: site_id
      )

  A read made with `authorize?: false` is the system's — the lock a page's head hands its gate, the
  components a site's stylesheet has to carry — and is not filtered.

  A record is also left out when the runtime page that serves its address is locked to permissions
  the reader does not hold: while every page that shows a post, a category, a tag, a blogger or a
  team (`/blog/:slug`, whatever path the page was given) is, no record of that kind is read, counted
  or listed for the reader, a comment of such a post included, and one asked for alone is not found.
  The pages are read in the statement of the read itself
  (`MishkaBlog.Resources.Preparations.ReaderLocks`), from the `pages` table, for the JSON:API and
  GraphQL as for a page of the site.

  WHAT A READ IS KEPT TO is a filter on the read itself, built from the names the reader holds
  (`MishkaBlog.Resources.Preparations.ReaderLocks`), so the database answers it beside the rows
  and nothing is read beforehand, whether anything is locked or not:

    * a category — by its own lock, or the nearest one above it;
    * a tag — by its own lock;
    * a post — by its own lock; one that names none, unless it is filed under a locked category and
      under none the reader may open;
    * a comment (`:comment`) — by its post's.

  A record asked for by itself (`get?`) is read with whether it opens for the reader beside it, and
  is left out of the result when it does not, so it is not found.

  IN A READ OF CATEGORIES, TAGS OR BLOGGERS, what is counted, sorted by or asked of their posts is of
  the posts the reader may open: an aggregate over them, such as a category's `published_post_count`
  or a blogger's `post_count`, in a list or asked for alone, and an `exists(tenant_posts, …)` filter,
  such as a block's leaving out of rows with nothing to read.

  ## Options

  * `:kind` - Required. `:post`, `:category`, `:tag`, `:comment`, `:blogger` or `:team`. The last two
    are left out only by the page that serves them: they carry no lock of their own.
  """
  use Ash.Resource.Preparation

  require Ash.Expr
  require Ash.Query

  alias MishkaBlog.BlogPost
  alias MishkaBlog.Resources.Preparations.ReaderLocks
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @impl true
  def init(opts) do
    if opts[:kind] in [:post, :category, :tag, :comment, :blogger, :team],
      do: {:ok, opts},
      else: {:error, "kind is one of :post, :category, :tag, :comment, :blogger or :team"}
  end

  @impl true
  def prepare(query, opts, context) do
    case reader(context) do
      :system -> query
      {:reader, actor} -> keep(query, opts[:kind], ReaderLocks.of(actor))
    end
  end

  @doc """
  Whether `actor` may open a record that opens with `required`: anyone when it names none, else an
  actor holding one of them, as the record's page asks (`AccessPermissions.match?/3`).
  """
  @spec opens?([String.t()] | nil, map() | nil) :: boolean()
  def opens?(required, _actor) when required in [nil, []], do: true
  def opens?(_required, nil), do: false
  def opens?(required, actor), do: AccessPermissions.match?(actor, %{}, permissions: required)

  defp reader(%{authorize?: false}), do: :system
  defp reader(%{actor: actor}), do: {:reader, actor}

  # A blogger or a team opens with no lock of its own; only the page that serves it can close it. What
  # a blogger's posts are counted as is the reader's, as a category's and a tag's are.
  defp keep(query, kind, reader) when kind in [:blogger, :team] do
    on_site(query, fn query, site_id ->
      query
      |> Ash.Query.filter(^opens(kind, reader, ReaderLocks.site(site_id)))
      |> counted(kind, site_id, reader)
    end)
  end

  defp keep(%{action: %{get?: true}} = query, kind, reader) do
    query
    |> Ash.Query.calculate(
      :open_to_reader?,
      :boolean,
      opens(kind, reader, ReaderLocks.own_site())
    )
    |> on_site(fn query, site_id -> counted(query, kind, site_id, reader) end)
    |> Ash.Query.after_action(&admit/2)
  end

  defp keep(query, kind, reader) do
    on_site(query, fn query, site_id ->
      query
      |> Ash.Query.filter(^opens(kind, reader, ReaderLocks.site(site_id)))
      |> counted(kind, site_id, reader)
    end)
  end

  defp on_site(query, narrow) do
    Ash.Query.before_action(query, fn
      %{tenant: site_id} = query when is_binary(site_id) -> narrow.(query, site_id)
      query -> query
    end)
  end

  defp opens(:post, reader, site), do: ReaderLocks.post(reader, site)
  defp opens(:category, reader, site), do: ReaderLocks.category(reader, site)

  defp opens(:tag, reader, site),
    do:
      Ash.Expr.expr(
        ^ReaderLocks.page_open(reader, "blog:tag", site) and ^ReaderLocks.opens(reader)
      )

  defp opens(:comment, reader, site), do: ReaderLocks.comment(reader, site)
  defp opens(:blogger, reader, site), do: ReaderLocks.page_open(reader, "blog:author", site)
  defp opens(:team, reader, site), do: ReaderLocks.page_open(reader, "blog:team", site)

  # A record that does not open for the reader is not in the result, the way a page is not found.
  defp admit(_query, records),
    do: {:ok, Enum.filter(records, &(&1.calculations[:open_to_reader?] == true))}

  defp counted(query, kind, site_id, reader) when kind in [:category, :tag, :blogger],
    do: to_open_posts(query, ReaderLocks.post(reader, ReaderLocks.site(site_id)))

  defp counted(query, _kind, _site_id, _reader), do: query

  # The hook runs after Ash has built the read's aggregates, its sort and its filter, so each one
  # over the row's posts is narrowed where it stands.
  defp to_open_posts(query, open) do
    {:ok, %{expression: opened}} = Ash.Filter.parse(BlogPost, open)

    narrow = fn
      %Ash.Query.Aggregate{relationship_path: path} = aggregate ->
        if posts?(query.resource, path),
          do: %{aggregate | query: Ash.Query.filter(aggregate.query, ^open)},
          else: aggregate

      field ->
        field
    end

    %{
      query
      | aggregates: Map.new(query.aggregates, fn {name, field} -> {name, narrow.(field)} end),
        sort: Enum.map(query.sort, fn {field, order} -> {narrow.(field), order} end),
        filter:
          Ash.Filter.map(query.filter, fn
            %Ash.Query.Exists{at_path: [], path: path} = exists ->
              if posts?(query.resource, path),
                do:
                  {:halt,
                   %{exists | expr: Ash.Query.BooleanExpression.new(:and, exists.expr, opened)}},
                else: exists

            expression ->
              expression
          end)
    }
  end

  defp posts?(resource, path), do: Ash.Resource.Info.related(resource, path) == BlogPost
end
