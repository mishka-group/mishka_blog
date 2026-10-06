defmodule MishkaBlog.Resources.Preparations.SiteAskedOn do
  @moduledoc """
  Keeps a public list to the site it is asked on: only the rows whose `:through` record belongs to
  the tenant.

  - With no tenant, the list is empty.
  - A site user (an actor with a `site_id`) gets an empty list on any tenant but its own site. A
    master, or a visitor with no actor, gets the list of the site it names.
  - A call made with `authorize?: false` is not filtered.

      prepare {MishkaBlog.Resources.Preparations.SiteAskedOn, through: :team}

  ## Options

  * `:through` - Required. The relationship to the record that carries the `site_id`.
  """
  use Ash.Resource.Preparation

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :through) do
      {:ok, through} when is_atom(through) -> {:ok, opts}
      _missing -> {:error, "through is required"}
    end
  end

  @impl true
  def prepare(query, _opts, %{authorize?: false}), do: query

  def prepare(query, _opts, %{tenant: nil}), do: Ash.Query.do_filter(query, false)

  def prepare(query, _opts, %{tenant: tenant, actor: %{site_id: site_id}})
      when is_binary(site_id) and site_id != tenant,
      do: Ash.Query.do_filter(query, false)

  def prepare(query, opts, %{tenant: tenant}),
    do: Ash.Query.do_filter(query, [{opts[:through], [site_id: tenant]}])
end
