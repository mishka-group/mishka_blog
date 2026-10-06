defmodule MishkaBlog.Test.TeamPermissionAreaTest do
  @moduledoc """
  A team's permissions are permission management, not blog editing: attaching, replacing or
  removing them needs the permission area besides the blog's post area, and a site's admin attaches
  only what it holds itself — through `MishkaBlog.Team` and through `MishkaBlog.TeamPermission`
  alike. Editing the rest of a team needs the post area alone.
  """
  use MishkaBlog.DataCase, async: false

  require Ash.Query

  alias MishkaBlog.{Team, TeamPermission}
  alias MishkaCmsCore.Accounts.Permission

  @post "admin:dashboard:blog:post"
  @permission "admin:dashboard:permission"

  setup do
    site = create_site!()

    %{
      site: site,
      editor: create_user_with_permissions!([@post], site_id: site.id),
      manager: create_user_with_permissions!([@post, @permission], site_id: site.id),
      granter: create_user_with_permissions!([@permission], site_id: site.id),
      held: permission_id(@post),
      beyond: permission_id("admin:dashboard:runtime:page")
    }
  end

  defp permission_id(name) do
    case Permission |> Ash.Query.filter(name == ^name) |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> create_permission!(name: name).id
      {:ok, permission} -> permission.id
    end
  end

  defp create_team(ctx, actor, params) do
    Team
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{name: "Desk", slug: "desk-#{System.unique_integer([:positive])}"}, params),
      actor: actor,
      tenant: ctx.site.id
    )
    |> Ash.create()
  end

  defp update_team(ctx, action, team, params, actor) do
    team
    |> Ash.Changeset.for_update(action, params, actor: actor, tenant: ctx.site.id)
    |> Ash.update()
  end

  defp attached(team) do
    TeamPermission
    |> Ash.Query.filter(team_id == ^team.id)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.permission_id)
  end

  describe "creating a team" do
    test "without permissions needs the post area alone", ctx do
      assert {:ok, _team} = create_team(ctx, ctx.editor, %{})
    end

    test "with permissions needs the permission area too", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               create_team(ctx, ctx.editor, %{permission_ids: [ctx.held]})

      assert {:error, %Ash.Error.Forbidden{}} =
               create_team(ctx, ctx.granter, %{permission_ids: [ctx.held]})

      assert {:ok, team} = create_team(ctx, ctx.manager, %{permission_ids: [ctx.held]})
      assert attached(team) == [ctx.held]
    end

    test "attaches only what the admin holds", ctx do
      assert {:error, %Ash.Error.Invalid{} = error} =
               create_team(ctx, ctx.manager, %{permission_ids: [ctx.beyond]})

      assert Exception.message(error) =~ "cannot grant permissions you do not hold yourself"
    end
  end

  describe "an existing team" do
    setup ctx do
      %{team: create_team!(site_id: ctx.site.id)}
    end

    test "is edited by a holder of the post area alone", ctx do
      assert {:ok, %{name: "Renamed"}} =
               update_team(ctx, :update, ctx.team, %{name: "Renamed"}, ctx.editor)
    end

    test "has its permissions replaced only with the permission area", ctx do
      params = %{permission_ids: [ctx.held]}

      assert {:error, %Ash.Error.Forbidden{}} =
               update_team(ctx, :update, ctx.team, params, ctx.editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               update_team(ctx, :assign_permissions, ctx.team, params, ctx.editor)

      assert {:error, %Ash.Error.Forbidden{}} =
               update_team(ctx, :assign_permissions, ctx.team, params, ctx.granter)

      assert {:ok, _team} = update_team(ctx, :assign_permissions, ctx.team, params, ctx.manager)
      assert attached(ctx.team) == [ctx.held]
    end

    test "is sent its permissions, even none, only with the permission area", ctx do
      assert {:error, %Ash.Error.Forbidden{}} =
               update_team(ctx, :assign_permissions, ctx.team, %{permission_ids: []}, ctx.editor)

      assert {:ok, _team} =
               update_team(ctx, :assign_permissions, ctx.team, %{permission_ids: []}, ctx.manager)
    end

    test "gains and loses one permission only with the permission area", ctx do
      params = %{permission_id: ctx.held}

      assert {:error, %Ash.Error.Forbidden{}} =
               update_team(ctx, :add_permission, ctx.team, params, ctx.editor)

      assert {:ok, _team} = update_team(ctx, :add_permission, ctx.team, params, ctx.manager)
      assert attached(ctx.team) == [ctx.held]

      assert {:error, %Ash.Error.Forbidden{}} =
               update_team(ctx, :remove_permission, ctx.team, params, ctx.editor)

      assert {:ok, _team} = update_team(ctx, :remove_permission, ctx.team, params, ctx.manager)
      assert attached(ctx.team) == []
    end

    test "is given only permissions the admin holds", ctx do
      for {action, params} <- [
            {:update, %{permission_ids: [ctx.beyond]}},
            {:assign_permissions, %{permission_ids: [ctx.beyond]}},
            {:add_permission, %{permission_id: ctx.beyond}}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 update_team(ctx, action, ctx.team, params, ctx.manager),
               "#{action} attached a permission the admin does not hold"
      end

      assert attached(ctx.team) == []
    end
  end

  describe "a team's permission row written directly" do
    setup ctx do
      %{team: create_team!(site_id: ctx.site.id)}
    end

    defp assign(ctx, permission_id, actor) do
      TeamPermission
      |> Ash.Changeset.for_create(:assign, %{team_id: ctx.team.id, permission_id: permission_id},
        actor: actor
      )
      |> Ash.create()
    end

    test "needs the permission area", ctx do
      assert {:error, %Ash.Error.Forbidden{}} = assign(ctx, ctx.held, ctx.editor)
      assert {:error, %Ash.Error.Forbidden{}} = assign(ctx, ctx.held, ctx.granter)
      assert {:ok, _row} = assign(ctx, ctx.held, ctx.manager)
    end

    test "names only a permission the admin holds", ctx do
      assert {:error, %Ash.Error.Invalid{}} = assign(ctx, ctx.beyond, ctx.manager)
      assert attached(ctx.team) == []
    end

    test "is removed only with the permission area", ctx do
      {:ok, row} = assign(ctx, ctx.held, ctx.manager)

      assert {:error, %Ash.Error.Forbidden{}} = Ash.destroy(row, actor: ctx.editor)
      assert :ok = Ash.destroy(row, actor: ctx.manager)
    end
  end
end
