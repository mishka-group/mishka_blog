# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Preparations.OpenToActor do
  @moduledoc """
  Keeps a public read to the records its reader may open, by the rule the record's page keeps: a
  record whose lock names permissions opens only for a reader holding one of them
  (`AccessPermissions.match?/3`), and never for a visitor who is not signed in. A list leaves out,
  in its own query, every record the reader may not open, so its pages and its count are of what
  the reader sees; asking for one of them by itself is refused as forbidden.

      prepare {OpenToActor, kind: :post}

  THE READER is the actor of an authorized read: the visitor a page reads for, as the blog's
  components pass it — `nil` for a visitor who is not signed in — and the JSON:API's caller.

      Ash.Query.for_read(MishkaBlog.BlogPost, :public_list, %{},
        actor: current_user,
        tenant: site_id
      )

  A read made with `authorize?: false` is the system's — the lock a page's head hands its gate, the
  components a site's stylesheet has to carry — and is not filtered.

  WHAT A LIST IS KEPT TO is worked out as it runs, from the site's locked records alone: the
  categories, each with the lock it opens with (`effective_permissions`), and the posts or tags that
  name a lock of their own. Each lock is matched once, and the list's query is filtered by the ids
  that come out:

    * a category or a tag — by its own lock, or a category's inherited one;
    * a post — by its own lock; one that names none, unless it is filed under a locked category and
      under none the reader may open;
    * a comment (`:comment`) — by its post's.

  IN A READ OF CATEGORIES OR TAGS, what is counted, sorted by or asked of their posts is of the posts
  the reader may open: an aggregate over them, such as `published_post_count`, in a list or asked for
  alone, and an `exists(tenant_posts, …)` filter, such as a block's leaving out of rows with nothing
  to read.

  ## Options

  * `:kind` - Required. `:post`, `:category`, `:tag` or `:comment`.
  """
  use Ash.Resource.Preparation

  require Ash.Expr
  require Ash.Query

  alias MishkaBlog.{BlogPost, Collection, Tag}
  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  # The calculation or attribute holding the lock each kind opens with, for one asked for alone.
  @locks %{post: :effective_permissions, category: :effective_permissions, tag: :permissions}

  @impl true
  def init(opts) do
    if opts[:kind] in [:post, :category, :tag, :comment],
      do: {:ok, opts},
      else: {:error, "kind is one of :post, :category, :tag or :comment"}
  end

  @impl true
  def prepare(query, opts, context) do
    case reader(context) do
      :system -> query
      {:reader, actor} -> keep(query, opts[:kind], actor)
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

  defp keep(%{action: %{get?: true}} = query, kind, actor) do
    query
    |> on_site(fn query, site_id -> counted(query, kind, site_id, actor) end)
    |> Ash.Query.after_action(fn query, records -> admit(query, records, kind, actor) end)
  end

  defp keep(query, kind, actor) do
    on_site(query, fn query, site_id -> listed(query, kind, site_id, actor) end)
  end

  defp on_site(query, narrow) do
    Ash.Query.before_action(query, fn
      %{tenant: site_id} = query when is_binary(site_id) -> narrow.(query, site_id)
      query -> query
    end)
  end

  # ---------------------------------------------------------------------------
  # A list
  # ---------------------------------------------------------------------------

  defp listed(query, kind, site_id, actor) when kind in [:post, :comment] do
    Ash.Query.filter(query, ^opens_post(kind, posts(site_id, actor), categories(site_id, actor)))
  end

  defp listed(query, :category, site_id, actor) do
    {_opened, closed} = categories = categories(site_id, actor)

    query
    |> Ash.Query.filter(^not_in(closed))
    |> to_open_posts(opens_post(:post, posts(site_id, actor), categories))
  end

  defp listed(query, :tag, site_id, actor) do
    {_opened, closed} = split(own_locks(Tag, site_id), actor)

    query
    |> Ash.Query.filter(^not_in(closed))
    |> to_open_posts(open_post(site_id, actor))
  end

  defp counted(query, kind, site_id, actor) when kind in [:category, :tag],
    do: to_open_posts(query, open_post(site_id, actor))

  defp counted(query, _kind, _site_id, _actor), do: query

  # The hook runs after Ash has built the read's aggregates, its sort and its filter, so each one
  # over the row's posts is narrowed where it stands.
  defp to_open_posts(query, true), do: query

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

  defp open_post(site_id, actor),
    do: opens_post(:post, posts(site_id, actor), categories(site_id, actor))

  defp posts(site_id, actor), do: split(own_locks(BlogPost, site_id), actor)
  defp categories(site_id, actor), do: split(category_locks(site_id), actor)

  # Which posts, or the comments of which, the reader may open: `true` when none is closed to it.
  defp opens_post(kind, {opened_own, closed_own}, {opened, closed}) do
    case {kind, closed_own, closed} do
      {_kind, [], []} ->
        true

      {:post, _closed_own, []} ->
        Ash.Expr.expr(id not in ^closed_own)

      {:comment, _closed_own, []} ->
        Ash.Expr.expr(post_id not in ^closed_own)

      {:post, _closed_own, _closed} ->
        locked = opened ++ closed

        Ash.Expr.expr(
          id not in ^closed_own and
            (id in ^opened_own or not exists(tenant_collections, id in ^locked) or
               exists(tenant_collections, id in ^opened))
        )

      {:comment, _closed_own, _closed} ->
        locked = opened ++ closed

        Ash.Expr.expr(
          post_id not in ^closed_own and
            (post_id in ^opened_own or not exists(post.tenant_collections, id in ^locked) or
               exists(post.tenant_collections, id in ^opened))
        )
    end
  end

  defp not_in([]), do: true
  defp not_in(closed), do: Ash.Expr.expr(id not in ^closed)

  # The ids of these locked records the reader may open, and those it may not. Each distinct lock is
  # matched once.
  defp split(locks, actor) do
    answers =
      locks
      |> Map.values()
      |> Enum.uniq()
      |> Map.new(&{&1, opens?(&1, actor)})

    Enum.reduce(locks, {[], []}, fn {id, required}, {opened, closed} ->
      if Map.fetch!(answers, required), do: {[id | opened], closed}, else: {opened, [id | closed]}
    end)
  end

  # Every category of the site that opens with a lock, its own or one above it, by id.
  defp category_locks(site_id) do
    Collection
    |> Ash.Query.select([:id])
    |> Ash.Query.load(:effective_permissions)
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Enum.reject(&(&1.effective_permissions == []))
    |> Map.new(&{&1.id, &1.effective_permissions})
  end

  # Every record of `resource` on the site that names a lock of its own, by id.
  defp own_locks(resource, site_id) do
    resource
    |> Ash.Query.filter(not is_nil(permissions) and permissions != [])
    |> Ash.Query.select([:id, :permissions])
    |> Ash.read!(tenant: site_id, authorize?: false, page: false)
    |> Map.new(&{&1.id, &1.permissions})
  end

  # ---------------------------------------------------------------------------
  # One asked for alone
  # ---------------------------------------------------------------------------

  defp admit(query, records, kind, actor) do
    locks = locks(query.resource, Map.fetch!(@locks, kind), records, query.tenant)

    case Enum.reject(records, &opens?(locks, &1.id, actor)) do
      [] -> {:ok, records}
      _closed -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  # A record whose lock is not found — its row gone — opens for no one.
  defp opens?(locks, id, actor) do
    case Map.fetch(locks, id) do
      {:ok, required} -> opens?(required, actor)
      :error -> false
    end
  end

  # The lock of each of these records, read as the system: a hook runs before the query's own
  # loads, and the caller may have selected fields the lock needs away.
  defp locks(_resource, _lock, [], _tenant), do: %{}

  defp locks(resource, lock, records, tenant) do
    ids = Enum.map(records, & &1.id)

    resource
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id])
    |> with_field(lock)
    |> Ash.read!(tenant: tenant, authorize?: false, page: false)
    |> Map.new(&{&1.id, Map.get(&1, lock)})
  end

  # An attribute is selected, a calculation loaded.
  defp with_field(query, field) do
    case Ash.Resource.Info.attribute(query.resource, field) do
      nil -> Ash.Query.load(query, field)
      _attribute -> Ash.Query.ensure_selected(query, [field])
    end
  end
end
