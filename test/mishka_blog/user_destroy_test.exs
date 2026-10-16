# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.UserDestroyTest do
  @moduledoc """
  Deleting an account that has edited a blog record.

  The version trail of a post, tag, collection, team, blogger and auto-posting keeps the id of the
  account that made each change. Deleting that account leaves every version in place with
  `user_id` nil, so the trail outlives its author instead of refusing the delete with a raw
  `Ecto.ConstraintError`.

  `every foreign key to users` reads the database rather than a list of the resources known today:
  a table added later that points at an account without saying what happens to it fails there, by
  name.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaCmsCore.Accounts.User

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # The resource, the factory that makes one, and the attribute an edit changes.
  @versioned [
    {MishkaBlog.BlogPost, :create_blog_post!, :title},
    {MishkaBlog.Tag, :create_blog_tag!, :name},
    {MishkaBlog.Collection, :create_collection!, :name},
    {MishkaBlog.Team, :create_team!, :name},
    {MishkaBlog.Blogger, :create_blogger!, :display_name},
    {MishkaBlog.AutoPosting, :create_auto_posting!, :name}
  ]

  setup do
    site = create_site!(active: true)

    %{
      site: site,
      master: create_user_with_permissions!(["*"]),
      worker: create_user!(site_id: site.id)
    }
  end

  # A record of `resource` on `site`, edited once by `actor`.
  defp edited!(resource, factory, field, site, actor) do
    record = apply(MishkaBlog.Test.Factory, factory, [[site_id: site.id]])

    record
    |> Ash.Changeset.for_update(:update, %{field => "edited by #{actor.id}"},
      tenant: site.id,
      actor: actor,
      authorize?: false
    )
    |> Ash.update!()

    versions(AshPaperTrail.Resource.Info.version_resource(resource), record.id, tenant: site.id)
  end

  defp gone?(user),
    do: match?({:ok, nil}, Ash.get(User, user.id, authorize?: false, error?: false))

  describe "an account that edited a record" do
    for {resource, factory, field} <- @versioned do
      test "is deleted, and the #{inspect(resource)} version it made stays with no author",
           %{site: site, master: master, worker: worker} do
        resource = unquote(resource)
        version_resource = AshPaperTrail.Resource.Info.version_resource(resource)

        [first | _] = made = edited!(resource, unquote(factory), unquote(field), site, worker)
        source_id = first.version_source_id

        authored = Enum.filter(made, &(&1.user_id == worker.id))
        assert authored != [], "the setup has to leave a version made by the account"

        assert :ok = Ash.destroy(worker, action: :table_destroy, actor: master)
        assert gone?(worker)

        kept = versions(version_resource, source_id, tenant: site.id)
        assert length(kept) == length(made)
        refute Enum.any?(kept, &(&1.user_id == worker.id))

        for version <- authored do
          assert %{user_id: nil} = Enum.find(kept, &(&1.id == version.id))
        end
      end
    end

    test "does not take another account's versions with it", %{
      site: site,
      master: master,
      worker: worker
    } do
      other = create_user!(site_id: site.id)

      edited!(MishkaBlog.Tag, :create_blog_tag!, :name, site, worker)

      [%{version_source_id: source_id} | _] =
        edited!(MishkaBlog.Tag, :create_blog_tag!, :name, site, other)

      assert :ok = Ash.destroy(worker, action: :table_destroy, actor: master)

      kept = versions(MishkaBlog.Tag.Version, source_id, tenant: site.id)

      assert Enum.any?(kept, &(&1.user_id == other.id))
    end
  end

  describe "every foreign key to users" do
    # `a` NO ACTION and `r` RESTRICT refuse the delete, which surfaces as a raw constraint error. A
    # key either goes with the account (`c`, what it owns) or lets go of it (`n`, history and
    # notes). A table that is neither has to refuse on purpose, with a message of its own, and be
    # named here when it does.
    test "lets the account go: it cascades or it is released" do
      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          @repo,
          """
          SELECT conrelid::regclass::text, conname, confdeltype::text
          FROM pg_constraint
          WHERE contype = 'f' AND confrelid = 'users'::regclass
          ORDER BY 1, 2
          """
        )

      assert rows != [], "the query found no foreign key to users at all"

      refusing = for [table, name, rule] <- rows, rule not in ["c", "n"], do: "#{table}.#{name}"

      assert refusing == [],
             "deleting an account is refused by #{Enum.join(refusing, ", ")}: " <>
               "give the reference `on_delete: :nilify` (history) or `:delete` (what the account owns)"
    end
  end
end
