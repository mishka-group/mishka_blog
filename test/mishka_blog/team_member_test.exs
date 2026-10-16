# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Test.TeamMemberTest do
  use MishkaBlog.ConnCase
  import MishkaBlog.Test.Factory
  alias MishkaBlog.TeamMember

  describe "TeamMember Resource Configuration" do
    test "resource uses correct table name" do
      table = AshPostgres.DataLayer.Info.table(TeamMember)
      assert table == "mishka_blog_team_members"
    end

    test "resource has UUID primary key" do
      team_member = create_team_member!()
      assert is_binary(team_member.id)
      assert String.length(team_member.id) == 36
    end

    test "resource has policy authorizer" do
      authorizers = Ash.Resource.Info.authorizers(TeamMember)
      assert Ash.Policy.Authorizer in authorizers
    end
  end

  describe "TeamMember assign action (primary)" do
    test "successfully assigns a blogger to a team" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      team_member =
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id,
            role: "editor"
          },
          authorize?: false
        )
        |> Ash.create!()

      assert team_member.team_id == team.id
      assert team_member.blogger_id == blogger.id
      assert team_member.role == "editor"
    end

    test "assigns a blogger to a team without role" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      team_member =
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id
          },
          authorize?: false
        )
        |> Ash.create!()

      assert team_member.team_id == team.id
      assert team_member.blogger_id == blogger.id
      assert is_nil(team_member.role)
    end

    test "upserts when assigning same blogger to same team" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      team_member1 =
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id,
            role: "writer"
          },
          authorize?: false
        )
        |> Ash.create!()

      team_member2 =
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id,
            role: "editor"
          },
          authorize?: false
        )
        |> Ash.create!()

      # Should be same record with updated role
      assert team_member1.id == team_member2.id
      assert team_member2.role == "editor"
    end

    test "allows same blogger to be member of different teams" do
      team1 = create_team!()
      team2 = create_team!(site_id: team1.site_id)
      blogger = create_blogger!(site_id: team1.site_id)

      member1 = create_team_member!(team_id: team1.id, blogger_id: blogger.id, role: "editor")
      member2 = create_team_member!(team_id: team2.id, blogger_id: blogger.id, role: "writer")

      assert member1.team_id == team1.id
      assert member2.team_id == team2.id
      assert member1.blogger_id == member2.blogger_id
      assert member1.id != member2.id
    end

    test "allows different bloggers to be members of same team" do
      team = create_team!()
      blogger1 = create_blogger!(site_id: team.site_id)
      blogger2 = create_blogger!(site_id: team.site_id)

      member1 = create_team_member!(team_id: team.id, blogger_id: blogger1.id, role: "editor")
      member2 = create_team_member!(team_id: team.id, blogger_id: blogger2.id, role: "writer")

      assert member1.team_id == member2.team_id
      assert member1.blogger_id == blogger1.id
      assert member2.blogger_id == blogger2.id
      assert member1.id != member2.id
    end

    test "trims role value" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      team_member =
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id,
            role: "  editor  "
          },
          authorize?: false
        )
        |> Ash.create!()

      assert team_member.role == "editor"
    end

    test "sets joined_at timestamp" do
      team_member = create_team_member!()
      assert %DateTime{} = team_member.joined_at
    end
  end

  describe "TeamMember read action" do
    test "reads team member by id" do
      created_member = create_team_member!(role: "editor")

      read_member = Ash.get!(TeamMember, created_member.id, authorize?: false)

      assert read_member.id == created_member.id
      assert read_member.team_id == created_member.team_id
      assert read_member.blogger_id == created_member.blogger_id
      assert read_member.role == "editor"
    end

    test "lists all team members" do
      member1 = create_team_member!(role: "editor")
      member2 = create_team_member!(role: "writer")

      members = Ash.read!(TeamMember, authorize?: false)

      member_ids = Enum.map(members, & &1.id)
      assert member1.id in member_ids
      assert member2.id in member_ids
    end

    test "can query team members" do
      team = create_team!()

      member1 = create_team_member!(team_id: team.id, role: "editor")
      member2 = create_team_member!(team_id: team.id, role: "writer")

      members = Ash.read!(TeamMember, authorize?: false)

      member_ids = Enum.map(members, & &1.id)
      assert member1.id in member_ids
      assert member2.id in member_ids
    end

    test "supports multiple team members with different roles" do
      team = create_team!()
      blogger1 = create_blogger!(site_id: team.site_id)
      blogger2 = create_blogger!(site_id: team.site_id)

      member1 = create_team_member!(team_id: team.id, blogger_id: blogger1.id, role: "editor")
      member2 = create_team_member!(team_id: team.id, blogger_id: blogger2.id, role: "writer")

      members = Ash.read!(TeamMember, authorize?: false)

      assert length(members) >= 2
      member_ids = Enum.map(members, & &1.id)
      assert member1.id in member_ids
      assert member2.id in member_ids
    end
  end

  describe "TeamMember destroy action" do
    test "successfully removes a team member" do
      team_member = create_team_member!()
      member_id = team_member.id

      :ok = Ash.destroy(team_member, authorize?: false)

      assert_raise Ash.Error.Invalid, fn ->
        Ash.get!(TeamMember, member_id, authorize?: false)
      end
    end

    test "supports re-adding same blogger to same team" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      member1 = create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "editor")

      # Try to re-add same member (upsert will update)
      member2 = create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "writer")

      # Should be same record with updated role
      assert member1.id == member2.id
      assert member2.team_id == team.id
      assert member2.blogger_id == blogger.id
      assert member2.role == "writer"
    end
  end

  describe "TeamMember unique_team_member identity" do
    test "identity exists on team_id and blogger_id" do
      identities = Ash.Resource.Info.identities(TeamMember)
      unique_identity = Enum.find(identities, &(&1.name == :unique_team_member))

      assert unique_identity
      assert unique_identity.keys == [:team_id, :blogger_id]
    end

    test "upsert uses unique_team_member identity" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      # Create initial assignment
      member1 = create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "writer")

      # Try to create duplicate - should upsert
      member2 = create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "editor")

      # Should be same record
      assert member1.id == member2.id
      assert member2.role == "editor"

      # Should only have one record (verified by same ID)
      # The upsert ensures no duplicates exist
    end
  end

  describe "TeamMember role attribute" do
    test "role can be nil" do
      team_member = create_team_member!(role: nil)
      assert is_nil(team_member.role)
    end

    test "role can be a custom string" do
      team_member = create_team_member!(role: "senior-editor")
      assert team_member.role == "senior-editor"
    end

    test "role has max length constraint" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)
      long_role = String.duplicate("a", 101)

      assert_raise Ash.Error.Invalid, fn ->
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id,
            role: long_role
          },
          authorize?: false
        )
        |> Ash.create!()
      end
    end

    test "role within max length succeeds" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)
      max_role = String.duplicate("a", 100)

      team_member =
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: blogger.id,
            role: max_role
          },
          authorize?: false
        )
        |> Ash.create!()

      assert team_member.role == max_role
    end
  end

  describe "TeamMember relationships" do
    test "has team relationship" do
      team = create_team!()
      team_member = create_team_member!(team_id: team.id)

      # Verify relationship IDs match
      assert team_member.team_id == team.id

      # Can query team directly
      queried_team = Ash.get!(MishkaBlog.Team, team.id, action: :master_get, authorize?: false)
      assert queried_team.id == team.id
    end

    test "has blogger relationship" do
      blogger = create_blogger!()
      team_member = create_team_member!(blogger_id: blogger.id)

      # Verify relationship IDs match
      assert team_member.blogger_id == blogger.id

      # Can query blogger directly
      queried_blogger =
        Ash.get!(MishkaBlog.Blogger, blogger.id, action: :master_get, authorize?: false)

      assert queried_blogger.id == blogger.id
    end

    test "has both team and blogger relationship IDs" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)
      team_member = create_team_member!(team_id: team.id, blogger_id: blogger.id)

      assert team_member.team_id == team.id
      assert team_member.blogger_id == blogger.id
    end

    test "team_id cannot be nil" do
      blogger = create_blogger!()

      assert_raise Ash.Error.Invalid, fn ->
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: nil,
            blogger_id: blogger.id
          },
          authorize?: false
        )
        |> Ash.create!()
      end
    end

    test "blogger_id cannot be nil" do
      team = create_team!()

      assert_raise Ash.Error.Invalid, fn ->
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{
            team_id: team.id,
            blogger_id: nil
          },
          authorize?: false
        )
        |> Ash.create!()
      end
    end
  end

  describe "TeamMember authorization policies" do
    test "requires admin permissions" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      # Without authorize?: false, this should fail. The team's own site is named, so it is the
      # missing permission that refuses the write, not the site check.
      assert_raise Ash.Error.Forbidden, fn ->
        TeamMember
        |> Ash.Changeset.for_create(
          :assign,
          %{team_id: team.id, blogger_id: blogger.id, role: "editor"},
          tenant: team.site_id
        )
        |> Ash.create!()
      end
    end
  end

  describe "TeamMember joined_at timestamp" do
    test "joined_at is set automatically on create" do
      before_create = DateTime.utc_now()
      team_member = create_team_member!()
      after_create = DateTime.utc_now()

      assert DateTime.compare(team_member.joined_at, before_create) in [:gt, :eq]
      assert DateTime.compare(team_member.joined_at, after_create) in [:lt, :eq]
    end

    test "joined_at is preserved on upsert" do
      team = create_team!()
      blogger = create_blogger!(site_id: team.site_id)

      member1 = create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "writer")
      original_joined_at = member1.joined_at

      # Wait a bit to ensure timestamps would differ
      Process.sleep(10)

      member2 = create_team_member!(team_id: team.id, blogger_id: blogger.id, role: "editor")

      # joined_at should be the same (preserved from original)
      assert DateTime.compare(member2.joined_at, original_joined_at) == :eq
    end
  end
end
