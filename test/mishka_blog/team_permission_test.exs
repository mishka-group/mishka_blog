defmodule MishkaBlog.Test.TeamPermissionTest do
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory
  alias MishkaBlog.TeamPermission

  describe "TeamPermission Resource Configuration" do
    test "resource uses correct table name" do
      table = AshPostgres.DataLayer.Info.table(TeamPermission)
      assert table == "mishka_blog_team_permissions"
    end

    test "resource has UUID primary key" do
      team_permission = create_team_permission!()
      assert is_binary(team_permission.id)
      assert String.length(team_permission.id) == 36
    end

    test "resource has policy authorizer" do
      authorizers = Ash.Resource.Info.authorizers(TeamPermission)
      assert Ash.Policy.Authorizer in authorizers
    end

    test "resource does not have PaperTrail enabled" do
      extensions = Ash.Resource.Info.extensions(TeamPermission)
      refute AshPaperTrail.Resource in extensions
    end
  end

  describe "TeamPermission assign action (primary)" do
    test "successfully assigns a permission to a team" do
      team = create_team!()
      permission = create_permission!()

      team_permission =
        TeamPermission
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            permission_id: permission.id
          },
          authorize?: false
        )
        |> Ash.create!()

      assert team_permission.team_id == team.id
      assert team_permission.permission_id == permission.id
    end

    test "upserts when assigning same permission to same team" do
      team = create_team!()
      permission = create_permission!()

      team_permission1 =
        TeamPermission
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            permission_id: permission.id
          },
          authorize?: false
        )
        |> Ash.create!()

      team_permission2 =
        TeamPermission
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            permission_id: permission.id
          },
          authorize?: false
        )
        |> Ash.create!()

      # Should be same record
      assert team_permission1.id == team_permission2.id
    end

    test "allows same permission to be assigned to different teams" do
      team1 = create_team!()
      team2 = create_team!()
      permission = create_permission!()

      perm1 = create_team_permission!(team_id: team1.id, permission_id: permission.id)
      perm2 = create_team_permission!(team_id: team2.id, permission_id: permission.id)

      assert perm1.team_id == team1.id
      assert perm2.team_id == team2.id
      assert perm1.permission_id == perm2.permission_id
      assert perm1.id != perm2.id
    end

    test "allows different permissions to be assigned to same team" do
      team = create_team!()
      permission1 = create_permission!()
      permission2 = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission1.id)
      perm2 = create_team_permission!(team_id: team.id, permission_id: permission2.id)

      assert perm1.team_id == perm2.team_id
      assert perm1.permission_id == permission1.id
      assert perm2.permission_id == permission2.id
      assert perm1.id != perm2.id
    end

    test "sets created_at timestamp" do
      team_permission = create_team_permission!()
      assert %DateTime{} = team_permission.created_at
    end
  end

  describe "TeamPermission read action" do
    test "reads team permission from database" do
      created_perm = create_team_permission!()

      # TeamPermission has composite primary key (team_id + permission_id)
      # Query by these keys instead of id
      read_perms = Ash.read!(TeamPermission, authorize?: false)

      # Find our created permission in the list
      read_perm = Enum.find(read_perms, &(&1.id == created_perm.id))

      assert read_perm
      assert read_perm.team_id == created_perm.team_id
      assert read_perm.permission_id == created_perm.permission_id
    end

    test "lists all team permissions" do
      perm1 = create_team_permission!()
      perm2 = create_team_permission!()

      permissions = Ash.read!(TeamPermission, authorize?: false)

      permission_ids = Enum.map(permissions, & &1.id)
      assert perm1.id in permission_ids
      assert perm2.id in permission_ids
    end

    test "can query team permissions for verification" do
      team = create_team!()
      permission1 = create_permission!()
      permission2 = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission1.id)
      perm2 = create_team_permission!(team_id: team.id, permission_id: permission2.id)

      permissions = Ash.read!(TeamPermission, authorize?: false)

      permission_ids = Enum.map(permissions, & &1.id)
      assert perm1.id in permission_ids
      assert perm2.id in permission_ids
    end
  end

  describe "TeamPermission destroy action" do
    test "successfully removes a team permission" do
      team_permission = create_team_permission!()
      perm_id = team_permission.id

      assert :ok = Ash.destroy(team_permission, authorize?: false)

      # Verify it's gone by reading all and checking it's not in the list
      all_perms = Ash.read!(TeamPermission, authorize?: false)
      refute Enum.any?(all_perms, &(&1.id == perm_id))
    end

    test "allows removing and re-adding same permission to same team" do
      team = create_team!()
      permission = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission.id)
      Ash.destroy!(perm1, authorize?: false)

      perm2 = create_team_permission!(team_id: team.id, permission_id: permission.id)

      assert perm2.team_id == team.id
      assert perm2.permission_id == permission.id
    end
  end

  describe "TeamPermission unique_team_permission identity" do
    test "identity exists on team_id and permission_id" do
      identities = Ash.Resource.Info.identities(TeamPermission)
      unique_identity = Enum.find(identities, &(&1.name == :unique_team_permission))

      assert unique_identity
      assert unique_identity.keys == [:team_id, :permission_id]
    end

    test "upsert uses unique_team_permission identity" do
      team = create_team!()
      permission = create_permission!()

      # Create initial assignment
      perm1 = create_team_permission!(team_id: team.id, permission_id: permission.id)

      # Try to create duplicate - should upsert
      perm2 = create_team_permission!(team_id: team.id, permission_id: permission.id)

      # Should be same record
      assert perm1.id == perm2.id

      # Should only have one record (verified by same ID)
      # The upsert ensures no duplicates exist
    end
  end

  describe "TeamPermission composite primary key" do
    test "team_id is part of primary key" do
      relationships = Ash.Resource.Info.relationships(TeamPermission)
      team_rel = Enum.find(relationships, &(&1.name == :team))

      assert team_rel.primary_key? == true
    end

    test "permission_id is part of primary key" do
      relationships = Ash.Resource.Info.relationships(TeamPermission)
      permission_rel = Enum.find(relationships, &(&1.name == :permission))

      assert permission_rel.primary_key? == true
    end

    test "composite primary key enforces uniqueness" do
      team = create_team!()
      permission = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission.id)
      # Upsert behavior means we get the same record back
      perm2 = create_team_permission!(team_id: team.id, permission_id: permission.id)

      assert perm1.id == perm2.id
    end
  end

  describe "TeamPermission relationships" do
    test "has team relationship" do
      team = create_team!()
      team_permission = create_team_permission!(team_id: team.id)

      # Verify relationship IDs match
      assert team_permission.team_id == team.id

      # Can query team directly
      queried_team = Ash.get!(MishkaBlog.Team, team.id, action: :master_get, authorize?: false)
      assert queried_team.id == team.id
    end

    test "has permission relationship" do
      permission = create_permission!()
      team_permission = create_team_permission!(permission_id: permission.id)

      # Verify relationship IDs match
      assert team_permission.permission_id == permission.id

      # Can query permission directly
      queried_permission =
        Ash.get!(MishkaCmsCore.Accounts.Permission, permission.id, authorize?: false)

      assert queried_permission.id == permission.id
    end

    test "has both team and permission relationship IDs" do
      team = create_team!()
      permission = create_permission!()
      team_permission = create_team_permission!(team_id: team.id, permission_id: permission.id)

      assert team_permission.team_id == team.id
      assert team_permission.permission_id == permission.id
    end

    test "team_id cannot be nil" do
      permission = create_permission!()

      assert_raise Ash.Error.Invalid, fn ->
        TeamPermission
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: nil,
            permission_id: permission.id
          },
          authorize?: false
        )
        |> Ash.create!()
      end
    end

    test "permission_id cannot be nil" do
      team = create_team!()

      assert_raise Ash.Error.Invalid, fn ->
        TeamPermission
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            permission_id: nil
          },
          authorize?: false
        )
        |> Ash.create!()
      end
    end
  end

  describe "TeamPermission authorization policies" do
    test "requires admin permissions" do
      team = create_team!()
      permission = create_permission!()

      # Without authorize?: false, this should fail. The team's own site is named, so it is the
      # missing permission that refuses the write, not the site check.
      assert_raise Ash.Error.Forbidden, fn ->
        TeamPermission
        |> Ash.Changeset.for_create(
          :assign,
          %{team_id: team.id, permission_id: permission.id},
          tenant: team.site_id
        )
        |> Ash.create!()
      end
    end
  end

  describe "TeamPermission created_at timestamp" do
    test "created_at is set automatically on create" do
      before_create = DateTime.utc_now()
      team_permission = create_team_permission!()
      after_create = DateTime.utc_now()

      assert DateTime.compare(team_permission.created_at, before_create) in [:gt, :eq]
      assert DateTime.compare(team_permission.created_at, after_create) in [:lt, :eq]
    end

    test "created_at is preserved on upsert" do
      team = create_team!()
      permission = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission.id)
      original_created_at = perm1.created_at

      # Wait a bit to ensure timestamps would differ
      Process.sleep(10)

      perm2 = create_team_permission!(team_id: team.id, permission_id: permission.id)

      # created_at should be the same (preserved from original)
      assert DateTime.compare(perm2.created_at, original_created_at) == :eq
    end
  end

  describe "TeamPermission bulk operations" do
    test "can assign multiple permissions to a team efficiently" do
      team = create_team!()
      permission1 = create_permission!()
      permission2 = create_permission!()
      permission3 = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission1.id)
      perm2 = create_team_permission!(team_id: team.id, permission_id: permission2.id)
      perm3 = create_team_permission!(team_id: team.id, permission_id: permission3.id)

      # Verify all permissions were created
      assert perm1.team_id == team.id
      assert perm2.team_id == team.id
      assert perm3.team_id == team.id

      assert perm1.permission_id == permission1.id
      assert perm2.permission_id == permission2.id
      assert perm3.permission_id == permission3.id
    end

    test "can assign a permission to multiple teams efficiently" do
      team1 = create_team!()
      team2 = create_team!()
      team3 = create_team!()
      permission = create_permission!()

      perm1 = create_team_permission!(team_id: team1.id, permission_id: permission.id)
      perm2 = create_team_permission!(team_id: team2.id, permission_id: permission.id)
      perm3 = create_team_permission!(team_id: team3.id, permission_id: permission.id)

      # Verify all assignments were created
      assert perm1.permission_id == permission.id
      assert perm2.permission_id == permission.id
      assert perm3.permission_id == permission.id

      assert perm1.team_id == team1.id
      assert perm2.team_id == team2.id
      assert perm3.team_id == team3.id
    end

    test "supports creating and managing team permissions" do
      team = create_team!()
      permission1 = create_permission!()
      permission2 = create_permission!()

      perm1 = create_team_permission!(team_id: team.id, permission_id: permission1.id)
      perm2 = create_team_permission!(team_id: team.id, permission_id: permission2.id)

      # Verify they exist
      assert perm1.id
      assert perm2.id

      # Can read them back
      permissions = Ash.read!(TeamPermission, authorize?: false)
      permission_ids = Enum.map(permissions, & &1.id)

      assert perm1.id in permission_ids
      assert perm2.id in permission_ids
    end
  end
end
