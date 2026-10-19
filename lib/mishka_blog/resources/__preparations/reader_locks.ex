# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Resources.Preparations.ReaderLocks do
  @moduledoc """
  What a reader may open, as the filter of the read that fetches the records: the answer
  `MishkaCmsCore.Accounts.Checks.AccessPermissions` gives for a record's lock, worked out by the
  database in the statement that reads the rows, so that no lock is read beforehand.

  The reader is the names its actor holds (`of/1`): a guest holds none, a user's are loaded with the
  actor. A lock opens for a reader when it names nothing, or when a name in it is covered by a name
  the reader holds, as `AccessPermissions.match?/3` asks it of a request from the dashboard:

    * a held name with no `*` segment covers the same name and nothing else;
    * a held name with a `*` segment covers a name of at least its number of segments whose segments
      agree with its own, a `*` standing for any one segment and, as its last segment, for the rest
      of the name, however many segments that is. `*` alone covers every name, `members:*` every
      name below `members`;
    * a name `admin:api:…` counts for nobody, whoever holds what.

  The held names with no `*` are compared as they are and the others as anchored regular
  expressions. `fragment/1` is used for that, and for nothing else of the matching, because Ash has
  no operator that tests each element of an array against a list of names and patterns. Everything
  else is an Ash expression.

  ## The page that serves a record

  A record is also kept from a reader the runtime page that serves its address is locked to. The
  pages are those of the site that show the kind of record (`page_open/3`: `extra["record"]` is
  `"blog:post"`, `"blog:category"`, `"blog:tag"`, `"blog:author"` or `"blog:team"`), active and not
  archived, and the kind opens for the reader when no page shows it or when one of them names no
  permission or names one the reader holds, as the page itself lets them in. It is a subquery of the
  read that does not depend on the row, so the database runs it once for the statement and no read
  is made beforehand; a site that locks no page opens every kind. The fragment names the table and
  the columns of the pages, which `MishkaBlog.ReaderLocksTest` keeps to the resource's.

  ## Records that inherit

  A post opens with its own lock, else with those of the categories it is filed under, each as the
  nearest category above it, or itself, that names some; it opens when none of them is locked or the
  reader may open one. A category opens with its own lock, else the nearest above it that names
  some. A comment opens with its post.

  The categories under a lock are found by a recursive query over the site's categories, which Ash
  has no operator for either. It is a subquery of the read that does not depend on the row, so the
  database runs it once for the statement, and it starts from the categories that name permissions:
  a site that locks nothing walks none. The fragments name the tables of the categories and of their
  posts, which `MishkaBlog.ReaderLocksTest` keeps to the resources'.
  """
  require Ash.Expr

  alias MishkaCmsCore.Accounts.Checks.AccessPermissions

  @enforce_keys [:exact, :patterns]
  defstruct [:exact, :patterns]

  @type t :: %__MODULE__{exact: [String.t()], patterns: [String.t()]}

  @doc """
  The names `actor` holds, as what a lock is matched against. `nil` holds none.
  """
  @spec of(map() | nil) :: t()
  def of(nil), do: %__MODULE__{exact: [], patterns: []}

  def of(actor) do
    {wildcards, exact} =
      actor
      |> AccessPermissions.with_permissions()
      |> Map.get(:permissions)
      |> List.wrap()
      |> Enum.flat_map(fn
        %{name: name} when is_binary(name) -> [name]
        _other -> []
      end)
      |> Enum.split_with(&wildcard?/1)

    %__MODULE__{
      exact: exact |> Enum.reject(&on_api?/1) |> Enum.uniq() |> Enum.sort(),
      patterns: wildcards |> Enum.map(&pattern/1) |> Enum.uniq() |> Enum.sort()
    }
  end

  @doc """
  Whether the runtime page that serves a record of `record` (`"blog:post"`, `"blog:category"`,
  `"blog:tag"`, `"blog:author"` or `"blog:team"`) is open to the reader, in `site` (see `site/1`):
  true when no page shows the kind, or when a page that does names no permission or one the reader
  holds.
  """
  @spec page_open(t(), String.t(), Ash.Expr.t()) :: Ash.Expr.t()
  def page_open(%__MODULE__{exact: exact, patterns: patterns}, record, site),
    do: open_page(exact, patterns, site, record)

  @doc """
  Whether a record whose lock is its `permissions` opens for the reader: it names nothing, or names
  something the reader holds.
  """
  @spec opens(t()) :: Ash.Expr.t()
  def opens(%__MODULE__{} = reader),
    do: Ash.Expr.expr(is_nil(permissions) or permissions == [] or ^holds(reader))

  @doc """
  Whether a post opens for the reader, in `site` (see `site/1`): its own lock when it names
  permissions, else those of the categories it is filed under. It opens when none of them is locked
  or when the reader may open one of them.
  """
  @spec post(t(), Ash.Expr.t()) :: Ash.Expr.t()
  def post(%__MODULE__{} = reader, site) do
    Ash.Expr.expr(
      ^page_open(reader, "blog:post", site) and
        if is_nil(permissions) or permissions == [] do
          not (^locked_post(site)) or ^opened_post(reader, site)
        else
          ^holds(reader)
        end
    )
  end

  @doc """
  Whether a category opens for the reader, in `site`: its own lock when it names permissions, else
  those of the nearest category above it that does.
  """
  @spec category(t(), Ash.Expr.t()) :: Ash.Expr.t()
  def category(%__MODULE__{} = reader, site) do
    Ash.Expr.expr(
      ^page_open(reader, "blog:category", site) and
        (not (^locked_category(site)) or ^opened_category(reader, site))
    )
  end

  @doc """
  Whether a comment opens for the reader, in `site`: whoever may open its post. A comment whose post
  is gone opens, as it does for the posts' read.
  """
  @spec comment(t(), Ash.Expr.t()) :: Ash.Expr.t()
  def comment(%__MODULE__{} = reader, site),
    do: Ash.Expr.expr(not exists(post, not (^post(reader, site))))

  @doc """
  The site a read is made in, as the id the categories are walked in: the one a list's query runs
  for.
  """
  @spec site(String.t()) :: Ash.Expr.t()
  def site(site_id), do: Ash.Expr.expr(type(^site_id, :uuid))

  @doc """
  The site of the record itself, for a record asked for by itself.
  """
  @spec own_site() :: Ash.Expr.t()
  def own_site, do: Ash.Expr.expr(site_id)

  # The ids of the site's categories whose lock, their own or the nearest one above, names something:
  # the ones that name some, and every category under one that names none of its own, level after level.
  # A category under one that is gone, or archived, is not under it.
  @locked_ids """
  WITH RECURSIVE under_lock(id, site_id, lock) AS (
    SELECT c.id, c.site_id, c.permissions FROM mishka_blog_collections c
    WHERE c.site_id = ? AND c.archived_at IS NULL AND c.permissions IS NOT NULL AND c.permissions <> '{}'
    UNION
    SELECT ch.id, ch.site_id, u.lock FROM mishka_blog_collections ch
    JOIN under_lock u ON ch.parent_collection_id = u.id AND ch.site_id = u.site_id
    WHERE ch.archived_at IS NULL AND (ch.permissions IS NULL OR ch.permissions = '{}')
  )
  SELECT id FROM under_lock
  """

  @matches "EXISTS (SELECT 1 FROM unnest(%LOCK%) AS held WHERE held NOT LIKE 'admin:api:%' AND (held = ANY(?) OR held ~ ANY(?)))"

  @opened_ids @locked_ids <> " WHERE " <> String.replace(@matches, "%LOCK%", "lock")

  # The posts filed under one of those categories.
  @filed_under "SELECT pc.post_id FROM mishka_blog_post_collections pc WHERE pc.collection_id IN ("

  @in_locked_categories "? IN (" <> @locked_ids <> ")"
  @in_opened_categories "? IN (" <> @opened_ids <> ")"
  @in_locked_posts "? IN (" <> @filed_under <> @locked_ids <> "))"
  @in_opened_posts "? IN (" <> @filed_under <> @opened_ids <> "))"

  defmacrop in_locked_categories(site) do
    id = Macro.var(:id, nil)

    quote do
      Ash.Expr.expr(fragment(unquote(@in_locked_categories), unquote(id), ^unquote(site)))
    end
  end

  defmacrop in_locked_posts(site) do
    id = Macro.var(:id, nil)

    quote do
      Ash.Expr.expr(fragment(unquote(@in_locked_posts), unquote(id), ^unquote(site)))
    end
  end

  defmacrop in_opened_categories(site, exact, patterns) do
    id = Macro.var(:id, nil)

    quote do
      Ash.Expr.expr(
        fragment(
          unquote(@in_opened_categories),
          unquote(id),
          ^unquote(site),
          type(^unquote(exact), {:array, :string}),
          type(^unquote(patterns), {:array, :string})
        )
      )
    end
  end

  defmacrop in_opened_posts(site, exact, patterns) do
    id = Macro.var(:id, nil)

    quote do
      Ash.Expr.expr(
        fragment(
          unquote(@in_opened_posts),
          unquote(id),
          ^unquote(site),
          type(^unquote(exact), {:array, :string}),
          type(^unquote(patterns), {:array, :string})
        )
      )
    end
  end

  # Whether a page of the site that shows a kind of record is open to the reader, true when none
  # shows it. `permissions` is NULL or empty for a page that names none.
  @pages_open """
  COALESCE((
    SELECT bool_or(
      pg.permissions IS NULL OR pg.permissions = '{}' OR EXISTS (
        SELECT 1 FROM unnest(pg.permissions) AS held
        WHERE held NOT LIKE 'admin:api:%' AND (held = ANY(?) OR held ~ ANY(?))
      )
    )
    FROM pages pg
    WHERE pg.site_id = ? AND pg.active AND pg.archived_at IS NULL AND pg.extra->>'record' = ?
  ), true)
  """

  defmacrop pages_open(exact, patterns, site, record) do
    quote do
      Ash.Expr.expr(
        fragment(
          unquote(@pages_open),
          type(^unquote(exact), {:array, :string}),
          type(^unquote(patterns), {:array, :string}),
          ^unquote(site),
          type(^unquote(record), :string)
        )
      )
    end
  end

  defmacrop holds_lock(exact, patterns) do
    sql = String.replace(@matches, "%LOCK%", "?")
    permissions = Macro.var(:permissions, nil)

    quote do
      Ash.Expr.expr(
        fragment(
          unquote(sql),
          unquote(permissions),
          type(^unquote(exact), {:array, :string}),
          type(^unquote(patterns), {:array, :string})
        )
      )
    end
  end

  defp open_page(exact, patterns, site, record), do: pages_open(exact, patterns, site, record)

  defp locked_category(site), do: in_locked_categories(site)

  defp opened_category(%__MODULE__{exact: [], patterns: []}, _site), do: false

  defp opened_category(%__MODULE__{exact: exact, patterns: patterns}, site),
    do: in_opened_categories(site, exact, patterns)

  defp locked_post(site), do: in_locked_posts(site)

  defp opened_post(%__MODULE__{exact: [], patterns: []}, _site), do: false

  defp opened_post(%__MODULE__{exact: exact, patterns: patterns}, site),
    do: in_opened_posts(site, exact, patterns)

  defp holds(%__MODULE__{exact: [], patterns: []}), do: false
  defp holds(%__MODULE__{exact: exact, patterns: patterns}), do: holds_lock(exact, patterns)

  defp wildcard?(name), do: "*" in String.split(name, ":")

  defp on_api?(name), do: String.starts_with?(name, "admin:api:")

  # `*` is any one segment, and the last segment, the rest of the name.
  defp pattern(name) do
    segments = String.split(name, ":")
    last = length(segments) - 1

    body =
      segments
      |> Enum.with_index()
      |> Enum.map_join(":", fn
        {"*", ^last} -> ".*"
        {"*", _inner} -> "[^:]*"
        {segment, _index} -> escape(segment)
      end)

    "^" <> body <> "$"
  end

  defp escape(segment), do: String.replace(segment, ~r/[\\^$.|?*+()\[\]{}]/, "\\\\\\0")
end
