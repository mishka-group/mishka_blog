# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Agent.OperationsTest do
  @moduledoc """
  Receipts for the blog's writes (`MishkaBlog.Plugins.AgentOperations`), publishing a post first:
  each stage is checked from its own evidence, the layers stay apart, and a publish the table does
  not show, or a schedule nothing will carry out, is never reported as done.
  """
  use MishkaBlog.DataCase, async: false

  alias MishkaBlog.BlogPost
  alias MishkaCmsCore.Agent.{Operation, Receipts}

  setup do
    Receipts.switch(true)
    on_exit(fn -> Receipts.switch(false) end)

    site = create_site!()

    admin =
      create_user_with_permissions!(
        ["admin:dashboard:blog:post", "admin:dashboard:agent:receipts"],
        site_id: site.id
      )

    master = create_user_with_permissions!(["*"])
    post = create_blog_post!(site_id: site.id, status: :draft, title: "A private draft title")
    {:ok, site: site, admin: admin, master: master, post: post}
  end

  defp stage(receipt, name), do: Enum.find(receipt.stages, &(&1.name == name))

  defp publish(post, site, opts \\ []) do
    post
    |> Ash.Changeset.for_update(:publish, %{}, tenant: site.id, authorize?: false)
    |> then(&Ash.Changeset.after_action(&1, Keyword.get(opts, :after, fn _c, r -> {:ok, r} end)))
  end

  test "every blog write is declared, and each one names what verifies it" do
    for action <-
          ~w(create update publish unpublish schedule destroy unarchive permanent_destroy restore_version),
        do: assert(%Operation{required: [_ | _]} = Operation.lookup("blog:blog_post:#{action}"))

    for kind <- ~w(collection tag),
        action <- ~w(create update destroy unarchive permanent_destroy),
        do: assert(%Operation{} = Operation.lookup("blog:#{kind}:#{action}"))
  end

  describe "blog:blog_post:publish" do
    test "a publish is verified stage by stage, each layer by its own evidence", %{
      site: site,
      admin: admin,
      post: post
    } do
      assert {:ok, published, receipt} =
               post
               |> Ash.Changeset.for_update(:publish, %{}, actor: admin, tenant: site.id)
               |> then(&Receipts.run("blog:blog_post:publish", &1, source: :agent))

      assert published.status == :published
      assert receipt.status == :verified
      assert receipt.subject_id == post.id
      assert receipt.site_id == site.id

      assert %{status: :verified} = stage(receipt, :dispatched)
      assert %{status: :verified} = stage(receipt, :validated)

      assert %{status: :verified, layer: :app, observed: %{source: :notifier}} =
               stage(receipt, :action_committed)

      assert %{
               status: :verified,
               layer: :db,
               observed: %{status: :published, published_at: :present}
             } =
               stage(receipt, :db_read_back)

      assert %{status: :verified, observed: %{correlated: :receipt, event: "publish"}} =
               stage(receipt, :broadcast_published)

      # Runtime jobs are off in a test run: skipped, never claimed.
      assert %{status: :skipped, reason: :off} = stage(receipt, :sitemap_job)
      assert %{status: :skipped, reason: :off} = stage(receipt, :sitemap_built)

      assert %{status: :verified, observed: %{correlated: :receipt}} =
               stage(receipt, :share_card_job)

      assert %{status: :unverified, reason: :pending} = stage(receipt, :share_card_looked)
      assert %{status: :verified} = stage(receipt, :feeds_dropped)

      assert %{status: :unverified, reason: :no_observer, layer: :ui} =
               stage(receipt, :ui_observed)

      refute inspect(receipt) =~ "private draft title"
      assert {:ok, _} = Receipts.get(receipt.id, admin)
    end

    test "a master publishes through the twin, and the receipt is the post's site", %{
      site: site,
      master: master,
      post: post
    } do
      unscoped = Ash.get!(BlogPost, post.id, action: :master_get, actor: master)

      assert {:ok, _post, receipt} =
               unscoped
               |> Ash.Changeset.for_update(:master_publish, %{}, actor: master)
               |> then(&Receipts.run("blog:blog_post:publish", &1))

      assert receipt.status == :verified
      assert receipt.action == :master_publish
      assert receipt.site_id == site.id
      assert receipt.actor.kind == :master
    end

    test "a publish whose row went back to draft fails the read-back, whatever the action said",
         %{
           site: site,
           post: post
         } do
      undo = fn _changeset, record ->
        {:ok, id} = Ecto.UUID.dump(record.id)

        MishkaBlog.Repo.query!("UPDATE mishka_blog_posts SET status = 'draft' WHERE id = $1", [id])

        {:ok, record}
      end

      assert {:ok, %{status: :published}, receipt} =
               Receipts.run("blog:blog_post:publish", publish(post, site, after: undo))

      assert %{status: :verified} = stage(receipt, :action_committed)

      assert %{
               status: :failed,
               reason: :mismatch,
               expected: %{status: :published},
               observed: %{status: :draft}
             } = stage(receipt, :db_read_back)

      assert receipt.status == :failed
    end

    test "another site's admin, one outside the posts area, or one without receipts cannot read it",
         %{
           site: site,
           post: post
         } do
      {:ok, _post, receipt} = Receipts.run("blog:blog_post:publish", publish(post, site))
      other = create_site!()

      for viewer <- [
            create_user_with_permissions!(
              ["admin:dashboard:blog:post", "admin:dashboard:agent:receipts"],
              site_id: other.id
            ),
            create_user_with_permissions!(
              ["admin:dashboard:blog:comment", "admin:dashboard:agent:receipts"],
              site_id: site.id
            ),
            create_user_with_permissions!(["admin:dashboard:blog:post"], site_id: site.id)
          ],
          do: assert({:error, :not_found} = Receipts.get(receipt.id, viewer))
    end
  end

  describe "the other post operations" do
    test "a schedule is partial: the post is scheduled, and nothing will publish it", %{
      site: site,
      post: post
    } do
      at = DateTime.utc_now() |> DateTime.add(3_600) |> DateTime.truncate(:second)

      assert {:ok, %{status: :scheduled}, receipt} =
               post
               |> Ash.Changeset.for_update(:schedule, %{scheduled_publish_at: at},
                 tenant: site.id,
                 authorize?: false
               )
               |> then(&Receipts.run("blog:blog_post:schedule", &1))

      assert %{status: :verified, observed: %{status: :scheduled}} = stage(receipt, :db_read_back)
      assert %{status: :skipped, reason: :no_publication} = stage(receipt, :broadcast_published)

      assert %{status: :unverified, reason: :nothing_publishes_it} =
               stage(receipt, :published_when_due)

      assert receipt.status == :partial
    end

    test "an unpublish is read back as a draft with no dates", %{site: site, post: post} do
      {:ok, published, _receipt} = Receipts.run("blog:blog_post:publish", publish(post, site))

      assert {:ok, _post, receipt} =
               published
               |> Ash.Changeset.for_update(:unpublish, %{}, tenant: site.id, authorize?: false)
               |> then(&Receipts.run("blog:blog_post:unpublish", &1))

      assert receipt.status == :verified

      assert %{observed: %{status: :draft, published_at: :absent, scheduled_publish_at: :absent}} =
               stage(receipt, :db_read_back)
    end

    test "an update is read back against what the action returned", %{site: site, post: post} do
      assert {:ok, _post, receipt} =
               post
               |> Ash.Changeset.for_update(:update, %{title: "Renamed in private"},
                 tenant: site.id,
                 authorize?: false
               )
               |> then(&Receipts.run("blog:blog_post:update", &1))

      assert receipt.status == :verified
      assert %{observed: %{title: :matches, slug: :matches}} = stage(receipt, :db_read_back)
      refute inspect(receipt) =~ "Renamed in private"
    end

    test "an archive and a permanent delete are read back straight from the table", %{
      site: site,
      post: post
    } do
      assert {:ok, archived, receipt} =
               post
               |> Ash.Changeset.for_destroy(:destroy, %{}, tenant: site.id, authorize?: false)
               |> then(&Receipts.run("blog:blog_post:destroy", &1))

      assert receipt.status == :verified

      assert %{observed: %{status: :archived, archived_at: :present}} =
               stage(receipt, :db_read_back)

      gone = create_blog_post!(site_id: site.id)

      assert {:ok, _post, receipt} =
               gone
               |> Ash.Changeset.for_destroy(:permanent_destroy, %{},
                 tenant: site.id,
                 authorize?: false
               )
               |> then(&Receipts.run("blog:blog_post:permanent_destroy", &1))

      assert receipt.status == :verified
      assert %{observed: %{present: false}} = stage(receipt, :db_read_back)
      assert archived.id == post.id
    end
  end

  test "with receipts off a publish is the publish alone", %{site: site, post: post} do
    Receipts.switch(false)

    assert {:ok, %BlogPost{status: :published}, nil} =
             Receipts.run("blog:blog_post:publish", publish(post, site))
  end
end
