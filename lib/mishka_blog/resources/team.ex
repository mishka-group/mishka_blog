# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Team do
  @moduledoc """
  Manages team structures in the MishkaBlog plugin with full versioning support.

  This resource represents teams that can contain multiple bloggers. Teams provide a way to
  organize bloggers into groups working on the same content areas.

  Each team belongs to a specific site and has a unique slug for URL identification.

  ## Permissions attached to a team

  A team can carry `MishkaCmsCore.Accounts.Permission` rows (`permission_ids`, and the
  `:assign_permissions`, `:add_permission` and `:remove_permission` actions). Changing them needs
  the permission area on the request's surface (`admin:dashboard:permission` or
  `admin:api:permission`) besides the blog's own post area, and a site's admin attaches only
  permissions it holds itself: each attached row is a `MishkaBlog.TeamPermission`, which asks
  `MishkaCmsCore.Accounts.Validations.GrantWithinActorScope`. Members do not inherit them: every
  gate reads the permissions a user holds itself.

  Team profiles feature full version control through PaperTrail integration, tracking
  all changes with snapshot-based history and the ability to restore previous versions.
  The resource implements soft deletion via archival and provides comprehensive
  metadata management for team organization.

  Database-level constraints ensure data integrity with slug validation and prevention
  of modifications to archived teams. Multi-tenant isolation ensures teams are properly
  segregated between sites. The resource provides extensive API actions for external
  integrations and maintains complete audit trails of all modifications.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshSlug,
      AshPaperTrail.Resource,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [
      Ash.Notifier.PubSub,
      MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook,
      MishkaCmsCore.Runtime.Resources.Notifiers.SitemapRefresh
    ]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  alias Ash.Error.Query.NotFound
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # A team card ends in labelled text buttons rather than icon squares, so each action carries the
  # whole button: the shared shape, then its own colour. `MishkaCmsCoreWeb.UIAdapters.Admin` draws
  # the icon at 15px, which the design sizes down to 13 — hence the `!`, since `size-*` is set by a
  # base utility too and the runtime compiler's bundle order is not reliable.
  @action_class "inline-flex items-center gap-[5px] bg-transparent p-0 text-[11.5px] " <>
                  "font-semibold transition-colors [&>span:not(.lbl)]:size-[13px]!"

  @edit_action_class @action_class <> " text-[#3a5bc4] hover:text-[#2b48a8]"
  @versions_action_class @action_class <> " text-[#7a5bd0] hover:text-[#5a3fb0]"
  @restore_action_class @action_class <> " text-[#177a53] hover:text-[#0f5e3f]"
  @danger_action_class @action_class <> " text-[#c0473d] hover:text-[#a5352c]"

  # A table row has no width for that many labelled buttons, so there the leading few become icon
  # squares and the rest fold into a kebab. Which copy a reader sees is decided per action by
  # `visible`, reading `state.template`.
  @table_template MishkaGervaz.Table.Templates.Table

  @square "grid size-[30px] flex-none place-items-center rounded-[8px] border transition-colors " <>
            "[&_.lbl]:hidden [&>span:not(.lbl)]:size-[15px]!"

  @square_action @square <>
                   " border-[#ecebe6] bg-[#faf9f6] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"

  @square_danger @square <> " border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"
  @square_restore @square <> " border-[#cfe8db] bg-[#f1f9f4] text-[#177a53] hover:bg-[#e6f6ee]"

  # The overflow actions ride in the kebab, each a full-width menu row: icon then label, left aligned.
  @menu_item "flex w-full items-center gap-2.5 rounded-[8px] px-2.5 py-[7px] text-[12px] " <>
               "font-semibold transition-colors [&_.lbl]:flex-1 [&_.lbl]:text-start"

  @menu_versions @menu_item <> " text-[#7a5bd0] hover:bg-[#f4ecfb]"
  @menu_danger @menu_item <> " text-[#c0473d] hover:bg-[#fbeceb]"

  @admin_fields [
    :name,
    :slug,
    :description,
    :avatar_url,
    :cover_image_url,
    :status,
    :site_id
  ]

  # Database configuration for teams storage with indexing
  postgres do
    table "mishka_blog_teams"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:status]
    end

    check_constraints do
      check_constraint :slug, "slug_length_check",
        check: "length(slug) >= 1 AND length(slug) <= 255",
        message: dgettext_noop("errors", "Slug must be between 1 and 255 characters.")

      check_constraint :slug, "no_empty_slug",
        check: "slug != ''",
        message: dgettext_noop("errors", "Slug cannot be empty.")

      check_constraint :name, "name_length",
        check: "length(name) >= 1 AND length(name) <= 255",
        message: dgettext_noop("errors", "Name must be between 1 and 255 characters.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_team_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_team_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived team'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_team_updates();"
      end

      statement :prevent_archived_team_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_team_updates_trigger
          BEFORE UPDATE ON mishka_blog_teams
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_team_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_team_updates_trigger ON mishka_blog_teams;"
      end
    end
  end

  # Soft deletion configuration using archived_at timestamp
  archive do
    exclude_read_actions [
      :any_state,
      :archived,
      :get_archived,
      :master_get_archived,
      :master_get,
      :master_archived
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  # Version control configuration for full team history tracking
  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    store_action_inputs? true
    ignore_attributes [:inserted_at, :updated_at, :archived_at]
    ignore_actions [:unarchive, :permanent_destroy, :master_unarchive, :master_permanent_destroy]
    attributes_as_attributes [:site_id]
    create_version_on_destroy? true
    only_when_changed? true
    relationship_opts public?: true

    # The version stays, with no author, when the account that made it is deleted.
    belongs_to_actor :user, MishkaCmsCore.Accounts.User,
      domain: MishkaCmsCore.Accounts,
      on_delete: :nilify

    version_extensions authorizers: [Ash.Policy.Authorizer]

    mixin {MishkaBlog.Resources.Mixins.PaperTrailMixin, :postgres, ["mishka_blog_team_versions"]}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "team"

    includes [
      :members,
      :master_members,
      :tenant_members,
      members: [:user],
      master_members: [:user],
      tenant_members: [:user]
    ]

    paginated_includes [
      :members,
      :master_members,
      :tenant_members,
      [:members, :user],
      [:master_members, :user],
      [:tenant_members, :user]
    ]
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :teams
        route "/admin/dashboard/blog/teams"
        stream_name :teams
      end

      source do
        preload do
          always [:site, :version_count, :member_count, :follower_count]
          tenant tenant_members: :members
          master master_members: :members
        end
      end

      columns do
        # A 44px tile plus the cell's own 16px padding either side. Left to the grid's first-column
        # default it would claim 1.7fr and open a gap the width of the name beside it.
        column :avatar do
          static true
          requires [:avatar_url, :name]
          label fn -> dgettext("mishka_gervaz", "Avatar") end

          ui do
            width "76px"
          end

          render fn record ->
            assigns = %{avatar_url: record.avatar_url, name: record.name}

            ~H"""
            <img
              :if={@avatar_url}
              src={@avatar_url}
              alt={@name}
              class="size-11 rounded-[10px] bg-[#f4f3ef] overflow-hidden object-cover text-transparent"
            />
            <div
              :if={is_nil(@avatar_url)}
              class="grid size-11 place-items-center rounded-[10px] bg-[#f4f3ef]"
            >
              <.icon name="hero-user-group" class="size-[18px] text-[#a8a5a0]" />
            </div>
            """
          end
        end

        # A team name and its slug are both short, so this takes the smallest share that fits them
        # and leaves the row's slack to :members_list, whose faces are what actually grow.
        column :name do
          static true
          requires [:id, :name, :slug]
          label fn -> dgettext("mishka_gervaz", "Name") end
          sortable true
          sort_field [:name]

          ui do
            width "minmax(170px,1.1fr)"
          end

          render fn record ->
            assigns = %{id: record.id, name: record.name, slug: record.slug}

            ~H"""
            <div class="min-w-0">
              <div class="truncate text-[13.5px] font-semibold text-[#17161a]">{@name}</div>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span class="truncate font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">
                  /{@slug}
                </span>
                <.copy_button id={"team-slug-copy-#{@id}"} value={@slug} label={gettext("Copy slug")} />
              </div>
            </div>
            """
          end
        end

        # Site and date share one cell, as every other table on the dashboard draws them: the site is
        # only meaningful to a master user, so a tenant reader gets the date alone rather than a
        # column repeating their own site on every row.
        column :site_datetime do
          static true
          requires [:site_id, :site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(140px,1.2fr)"
          end

          render fn record, state ->
            site_name = if record.site, do: record.site.name, else: nil

            assigns = %{
              site_name: site_name,
              date: MishkaCmsCore.Localized.date(record.inserted_at, :yMMMd),
              master_user?: state.master_user? and not is_nil(site_name)
            }

            ~H"""
            <div class="min-w-0">
              <div :if={@master_user?} class="flex items-center gap-[7px]">
                <svg
                  width="14"
                  height="14"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="#a8a5a0"
                  stroke-width="1.7"
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  class="shrink-0"
                >
                  <rect x="4" y="4" width="16" height="6" rx="1.5" />
                  <rect x="4" y="14" width="16" height="6" rx="1.5" />
                  <path d="M8 7h.01M8 17h.01" />
                </svg>
                <span class="truncate text-[12.5px] font-medium text-[#3a382f]">{@site_name}</span>
              </div>
              <div class={[
                "text-[11px] font-medium text-[#a8a5a0]",
                @master_user? && "mt-[3px] ps-[21px]"
              ]}>
                {@date}
              </div>
            </div>
            """
          end
        end

        # Three faces then a `+N` that expands the rest in place — the same cut-off and the same
        # marker `:tags` gives its chips, so both kinds of overflow on the dashboard read alike. The
        # palette is the card's own, so the two views tint a given face identically.
        column :members do
          label fn -> dgettext("mishka_gervaz", "Members") end
          visible fn state -> state.template.name() == :table end

          ui do
            type :avatars

            extra %{
              max_items: 3,
              label_field: :display_name,
              tints: MishkaBlogWeb.Templates.TeamCard.member_tints()
            }
          end
        end

        column :stats_info do
          static true
          requires [:member_count, :follower_count, :version_count]
          label fn -> dgettext("mishka_gervaz", "Stats") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(130px,1.1fr)"
          end

          render fn record ->
            assigns = %{
              member_count: record.member_count || 0,
              follower_count: record.follower_count || 0,
              version_count: record.version_count || 0
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-x-[11px] gap-y-1.5 text-[11.5px] font-semibold text-[#8a877f]">
              <span class="inline-flex items-center gap-[5px]" title={gettext("Members")}>
                <.icon name="hero-user-group" class="size-[13px] text-[#c3c0b8]" />
                {@member_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={gettext("Followers")}>
                <.icon name="hero-users" class="size-[13px] text-[#c3c0b8]" />
                {@follower_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={gettext("Versions")}>
                <.icon name="hero-clock" class="size-[13px] text-[#c3c0b8]" />
                {@version_count}
              </span>
            </div>
            """
          end
        end

        # The same three chips the card draws (`MishkaBlogWeb.Templates.TeamCard`), drawn here by the
        # `:badge` type rather than by hand, so the row keeps one badge shape with every other table.
        column :status do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Status") end
          visible fn state -> state.template.name() == :table end

          ui do
            type :badge
            width "minmax(110px,0.9fr)"

            extra %{
              colors: %{
                "active" => "bg-[#e6f6ee] text-[#177a53]",
                "inactive" => "bg-[#f2f1ec] text-[#6d6a63]",
                "draft" => "bg-[#fbf1df] text-[#a5691a]"
              },
              labels: %{
                "active" => dgettext_noop("mishka_gervaz", "Active"),
                "inactive" => dgettext_noop("mishka_gervaz", "Inactive"),
                "draft" => dgettext_noop("mishka_gervaz", "Draft")
              },
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:name, :slug, :description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
          end
        end

        filter :site_id, :relation do
          mode :search_multi
          display_field :name
          search_field :name
          min_chars 1
          page_size 15
          restricted true

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
            placeholder fn -> dgettext("mishka_gervaz", "Search sites...") end
          end
        end

        filter :status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Active"), :active},
              {dgettext("mishka_gervaz", "Inactive"), :inactive},
              {dgettext("mishka_gervaz", "Draft"), :draft}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end
      end

      row_actions do
        # Every action not living in the kebab has to be named here, card copy and table copy alike;
        # `visible` is what picks between them at render time.
        actions_layout do
          inline [
            :edit,
            :versions,
            :archive,
            :unarchive,
            :versions_archived,
            :permanent_destroy,
            :table_edit,
            :table_archive,
            :table_unarchive
          ]

          dropdown [:team_actions]
        end

        action :table_edit do
          type :edit
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("team-form-modal") end

          visible fn _record, state ->
            state.archive_status == :active and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @square_action
          end
        end

        action :table_archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this team?")
          end

          visible fn _record, state ->
            state.archive_status == :active and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
            class @square_danger
          end
        end

        action :table_unarchive do
          type :unarchive

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to restore this team?")
          end

          visible fn _record, state ->
            state.archive_status == :archived and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @square_restore
          end
        end

        dropdown :team_actions do
          ui do
            label fn -> dgettext("mishka_gervaz", "Actions") end
            icon "hero-ellipsis-vertical"
          end

          action :menu_versions do
            type :event
            event "show_versions"

            visible fn _record, state ->
              state.archive_status == :active and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Versions") end
              icon "hero-clock"
              class @menu_versions
            end
          end

          action :menu_versions_archived do
            type :event
            event "show_versions"

            visible fn _record, state ->
              state.archive_status == :archived and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Versions") end
              icon "hero-clock"
              class @menu_versions
            end
          end

          separator label: dgettext_noop("mishka_gervaz", "Permanent")

          action :menu_permanent_destroy do
            type :permanent_destroy

            confirm dgettext_noop(
                      "mishka_gervaz",
                      "Are you sure you want to PERMANENTLY delete this team? This action cannot be undone!"
                    )

            visible fn _record, state ->
              state.archive_status == :archived and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Delete forever") end
              icon "hero-x-circle"
              class @menu_danger
            end
          end
        end

        action :edit do
          type :edit

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("team-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @edit_action_class
          end
        end

        action :versions do
          type :event
          event "show_versions"

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Versions") end
            icon "hero-clock"
            class @versions_action_class
          end
        end

        action :archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this team?")
          end

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-trash"
            class @danger_action_class
          end
        end

        action :unarchive do
          type :unarchive

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to restore this team?")
          end

          visible fn _record, state ->
            state.archive_status == :archived and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @restore_action_class
          end
        end

        action :versions_archived do
          type :event
          event "show_versions"

          visible fn _record, state ->
            state.archive_status == :archived and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Versions") end
            icon "hero-clock"
            class @versions_action_class
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Are you sure you want to PERMANENTLY delete this team? This action cannot be undone!"
                  )

          visible fn _record, state ->
            state.archive_status == :archived and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete forever") end
            icon "hero-x-circle"
            class @danger_action_class
          end
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected teams?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected teams?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected teams? This cannot be undone."
            ),
          visible: :archived
      end

      realtime do
        prefix "team"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "teams"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No teams found"),
                  icon: "hero-user-group"

      presentation do
        template MishkaBlogWeb.Templates.TeamCard
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaBlogWeb.Templates.TeamCard
        ]
      end
    end

    form do
      identity do
        name :team_form
      end

      fields do
        field :site_id, :relation do
          restricted true
          required true
          show_on :create
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
          end
        end

        field :slug do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
          end
        end

        field :description, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 4
          end
        end

        field :avatar_url, :text do
          ui do
            label fn -> dgettext("mishka_gervaz", "Avatar") end
            extra %{dir: "ltr", media: :images, folder: "blog"}
          end
        end

        field :cover_image_url, :text do
          ui do
            label fn -> dgettext("mishka_gervaz", "Cover Image") end
            extra %{dir: "ltr", media: :images, folder: "blog"}
          end
        end

        # THE SHARE CARD a link to it shows, as drawn, and Regenerate. One being added has none yet.
        # `MishkaCmsCoreWeb.UIAdapters.Admin.text_input/1` is what reads `share_card`.
        field :share_card, :text do
          virtual true
          show_on :update

          ui do
            label fn -> dgettext("mishka_gervaz", "Share image") end
            extra %{share_card: &MishkaBlog.ShareCards.target/1}
          end
        end

        field :status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Active"), :active},
              {dgettext("mishka_gervaz", "Inactive"), :inactive},
              {dgettext("mishka_gervaz", "Draft"), :draft}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :name, :slug, :status]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :media do
          fields [:avatar_url, :cover_image_url, :share_card]

          ui do
            label fn -> dgettext("mishka_gervaz", "Media") end
            columns 2
          end
        end

        group :details do
          fields [:description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Details") end
            columns 1
          end
        end
      end

      # For `text_input/1` only — the adapter falls back to Tailwind for everything else. It is what
      # turns the pictures' `extra %{media: :images}` into a field filled from the media library.
      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        # While a team is added, its slug follows the name until the author types one.
        on_validate fn params, state ->
          MishkaCmsCore.Runtime.Helpers.follow_slug(params, state, :name)
        end

        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :slug, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :description, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(optional=[string])"

    field :avatar_url, :string, derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :cover_image_url, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :status, :atom, derives: "validate(atom, enum=Atom[active::inactive::draft])"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields
    field_policy [:version_count, :latest_version, :recent_versions] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # All other fields are publicly accessible
    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    default_accept @admin_fields

    create :create do
      primary? true
      accept List.delete(@admin_fields, :site_id)

      argument :permission_ids, {:array, :uuid} do
        description "List of permission IDs to assign to the team"
      end

      argument :member_ids, {:array, :uuid} do
        description "List of blogger IDs to add as team members"
      end

      validate present([:name, :slug])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      change manage_relationship(:member_ids, :tenant_members,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      description "Creates team for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      argument :permission_ids, {:array, :uuid} do
        description "List of permission IDs to assign to the team"
      end

      argument :member_ids, {:array, :uuid} do
        description "List of blogger IDs to add as team members"
      end

      validate present([:name, :slug, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      change manage_relationship(:member_ids, :members,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      description "Creates team for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      argument :permission_ids, {:array, :uuid} do
        description "List of permission IDs to assign to the team (replaces existing)"
      end

      argument :member_ids, {:array, :uuid} do
        description "List of blogger IDs to add as team members (replaces existing)"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived team. Please unarchive it first.")
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      change manage_relationship(:member_ids, :tenant_members,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      description "Updates team for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates team for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass

      argument :permission_ids, {:array, :uuid} do
        description "List of permission IDs to assign to the team (replaces existing)"
      end

      argument :member_ids, {:array, :uuid} do
        description "List of blogger IDs to add as team members (replaces existing)"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop("errors", "Cannot edit archived team. Please unarchive it first.")
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      change manage_relationship(:member_ids, :members,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )
    end

    read :by_slug do
      description "Reads team by slug within current tenant context"
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_by_slug do
      multitenancy :bypass
      description "Reads team by slug system-wide (master users only)"
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_read do
      description "Reads all teams system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    # The team in whatever state it is in, archived included, of the site asked for. The rows that
    # point at a team read it through their `team_in_any_state` relationship to tell its site.
    read :any_state do
      description "Reads a team in any state, archived included, of the site asked for"
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single team by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived teams within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived team for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived team for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived teams system-wide, bypassing tenant filtering"
    end

    read :public_list do
      description "Public endpoint to list all active teams (no authentication required)"
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      filter expr(status == :active)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :public_get do
      description "Public endpoint to get a single active team by ID (no authentication required)"
      get? true
      filter expr(status == :active)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :public_by_slug do
      description "Public endpoint to get a team by slug (no authentication required)"
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug) and status == :active)
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    update :assign_members do
      description "Replaces team's members with the provided list of blogger IDs"
      accept []
      require_atomic? false

      argument :blogger_ids, {:array, :uuid} do
        allow_nil? false
        description "List of blogger IDs to assign as team members"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:blogger_ids, :tenant_members,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_member do
      description "Adds a single blogger to the team"
      accept []
      require_atomic? false

      argument :blogger_id, :uuid do
        allow_nil? false
        description "Blogger ID to add to the team"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:blogger_id, :tenant_members, type: :append, on_no_match: :error)
    end

    update :remove_member do
      description "Removes a single blogger from the team"
      accept []
      require_atomic? false

      argument :blogger_id, :uuid do
        allow_nil? false
        description "Blogger ID to remove from the team"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:blogger_id, :tenant_members, type: :remove)
    end

    update :assign_permissions do
      description "Replaces team's permissions with the provided list of permission IDs"
      accept []
      require_atomic? false

      argument :permission_ids, {:array, :uuid} do
        allow_nil? false
        description "List of permission IDs to assign to the team"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:permission_ids, :permissions,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_permission do
      description "Adds a single permission to the team"
      accept []
      require_atomic? false

      argument :permission_id, :uuid do
        allow_nil? false
        description "Permission ID to add to the team"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:permission_id, :permissions, type: :append, on_no_match: :error)
    end

    update :remove_permission do
      description "Removes a single permission from the team"
      accept []
      require_atomic? false

      argument :permission_id, :uuid do
        allow_nil? false
        description "Permission ID to remove from the team"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:permission_id, :permissions, type: :remove)
    end

    destroy :destroy do
      description "Soft deletes team by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Team is already archived.")}
        else
          :ok
        end
      end

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :status, :inactive)
             end)
    end

    destroy :master_destroy do
      description "Soft deletes team by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Team is already archived.")}
        else
          :ok
        end
      end

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :status, :inactive)
             end)
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :active)

      atomic_upgrade_with :archived

      description "Restores archived team to active status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived team (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "Team is not archived.")
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :active)

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Permanently removes team and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes team and version history from database (master users) - bypasses multi-tenancy, irreversible and extremely dangerous"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    # VERSION MANAGEMENT ACTIONS

    read :get_with_versions do
      get? true
      description "Gets a single team with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.Team.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :master_get_with_versions do
      get? true
      multitenancy :bypass
      description "Gets a single team with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.Team.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a team with pagination (tenant users)"

      argument :team_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        team_id = Ash.Query.get_argument(query, :team_id)

        # First verify the team belongs to the tenant
        case Ash.get(MishkaBlog.Team, team_id, Ash.Scope.to_opts(context)) do
          {:ok, _team} ->
            query
            |> Ash.Query.filter(id == ^team_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaBlog.Team.Version
                |> Ash.Query.new()
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              NotFound.exception(resource: MishkaBlog.Team)
            )
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a team with pagination (master users)"

      argument :team_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        team_id = Ash.Query.get_argument(query, :team_id)

        query
        |> Ash.Query.filter(id == ^team_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaBlog.Team.Version
            |> Ash.Query.new()
        )
      end
    end

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the team to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived team. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.Team.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "team")}
    end

    action :restore_version_api, :struct do
      description "Restores team content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaBlog.Team

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        team_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaBlog.Team, team_id, Ash.Scope.to_opts(context, action: :read))
        |> case do
          {:ok, team} when not is_nil(team) ->
            if is_nil(team.archived_at) do
              tenant = team.site_id

              team
              |> Ash.Changeset.for_update(
                :restore_version,
                %{version_id: version_id},
                Ash.Scope.to_opts(context, tenant: tenant)
              )
              |> Ash.update()
            else
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived team. Please unarchive it first."
                       )
                   )
                 ]
               )}
            end

          _ ->
            {:error, NotFound.exception(resource: MishkaBlog.Team)}
        end
      end
    end

    update :master_restore_version do
      description "Restores team to a specific version state (master users)"
      accept []
      require_atomic? false
      transaction? true
      multitenancy :bypass

      argument :version_id, :uuid do
        allow_nil? false
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived team. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.Team.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "team")}
    end

    action :master_restore_version_api, :struct do
      description "Restores team to a specific version (master API users)"
      constraints instance_of: MishkaBlog.Team

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(
               MishkaBlog.Team,
               id,
               Ash.Scope.to_opts(context, action: :master_get, tenant: nil)
             ) do
          {:ok, record} when not is_nil(record) ->
            record
            |> Ash.Changeset.for_update(
              :master_restore_version,
              %{version_id: version_id},
              Ash.Scope.to_opts(context, tenant: nil)
            )
            |> Ash.update()

          _ ->
            {:error, NotFound.exception(resource: MishkaBlog.Team)}
        end
      end
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaBlog.Team

      argument :team_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :team_id,
           version: MishkaBlog.Team.Version,
           fields: List.delete(@admin_fields, :site_id),
           cast: [:status],
           label: dgettext_noop("errors", "team")}
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaBlog.Team

      argument :team_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :team_id,
           version: MishkaBlog.Team.Version,
           fields: List.delete(@admin_fields, :site_id),
           cast: [:status],
           master: true,
           label: dgettext_noop("errors", "team")}
    end
  end

  # Authorization policies for team access
  policies do
    # Allow public access to view active teams
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    bypass action(:public_by_slug) do
      authorize_if always()
    end

    # Admin access for all other actions
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # Sending a team's permissions at all — attaching, replacing or removing them — also needs the
    # permission area. Each row attached is held to what the actor holds by `MishkaBlog.TeamPermission`.
    policy [action_type([:create, :update]), changing_relationship(:permissions)] do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:permission", "admin:api:permission"]}
    end

    # A master reaches every site's rows; a site user only its own site's, whatever tenant it names.
    policy action_type([:read, :update, :destroy]) do
      authorize_if actor_attribute_equals(:site_id, nil)
      authorize_if expr(site_id == ^actor(:site_id))
    end
  end

  # PubSub configuration for real-time updates
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "team"

    # Tenant actions
    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_restore_version, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Multi-tenancy configuration - teams are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Teams are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Name of the team"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the team"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Description of the team's purpose and responsibilities"
    end

    attribute :avatar_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "URL of the team's avatar image"
    end

    attribute :cover_image_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "URL of the team's cover/banner image"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:active, :inactive, :draft]
      description "Status of the team (active, inactive, draft)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this team belongs to"
    end

    many_to_many :permissions, MishkaCmsCore.Accounts.Permission do
      description "Permissions granted to this team"
      through MishkaBlog.TeamPermission
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :permission_id
    end

    # Relationship - for public with tenant
    many_to_many :members, MishkaBlog.Blogger do
      public? true
      description "Bloggers who are members of this team (public access)"
      through MishkaBlog.TeamMember
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :blogger_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_members, MishkaBlog.Blogger do
      public? true
      description "Bloggers who are members of this team (tenant admin access)"
      through MishkaBlog.TeamMember
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :blogger_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_members, MishkaBlog.Blogger do
      public? true
      description "Bloggers who are members of this team (master admin access, bypass tenant)"
      through MishkaBlog.TeamMember
      source_attribute_on_join_resource :team_id
      destination_attribute_on_join_resource :blogger_id
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :followers, MishkaBlog.TeamFollower do
      public? true
      destination_attribute :team_id
      description "Users following this team"
    end

    # Version history relationship
    # Loaded through `:sorted_versions` as whoever runs the read. A version query handed to a load
    # is left unbuilt (`Ash.Query.new/1`) so that this action builds it for that reader.
    has_many :sorted_versions, MishkaBlog.Team.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      read_action :sorted_versions
      sort version_inserted_at: :desc
      description "Versions sorted by insertion time (newest first)"
    end
  end

  calculations do
    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaBlog.Team.Version
      description "Returns the most recent version for the team"

      calculation fn records, context ->
        team_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^team_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn team ->
          Map.get(versions_map, team.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaBlog.Team.Version]

      description "Returns the 10 most recent versions for the team in descending order by insertion date"

      calculation fn records, context ->
        team_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaBlog.Team.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^team_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn team ->
          Map.get(versions_map, team.id, [])
        end)
      end
    end
  end

  aggregates do
    count :member_count, :tenant_members do
      public? true
      authorize? false
      multitenancy :bypass
    end

    count :follower_count, :followers do
      public? true
      authorize? false
    end

    count :version_count, :sorted_versions do
      public? true
      multitenancy :bypass
    end
  end

  identities do
    identity :unique_slug_per_site, [:slug, :site_id] do
      description "Ensures team slugs are unique within each site for clear identification"
      message dgettext_noop("errors", "Team slug must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end
  end
end
