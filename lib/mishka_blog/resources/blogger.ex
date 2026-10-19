# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Blogger do
  @moduledoc """
  Manages blogger profiles in the MishkaBlog plugin with full versioning support.

  This resource represents blogger profiles that are associated with users who can
  create blog posts. Each blogger profile belongs to a specific site and contains
  professional information including bio, expertise areas, social links, and publishing
  permissions. The slug field provides a unique URL identifier for each blogger.

  Blogger profiles feature full version control through PaperTrail integration, tracking
  all changes with snapshot-based history and the ability to restore previous versions.
  The resource implements soft deletion via archival and provides comprehensive
  metadata management for public-facing blogger profiles.

  Database-level constraints ensure data integrity with slug validation and prevention
  of modifications to archived profiles. Multi-tenant isolation ensures blogger profiles
  are properly segregated between sites. The resource provides extensive API actions
  for external integrations and maintains complete audit trails of all modifications.
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
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # The card keeps every action as an inline text button, as the design draws it; a table row has no
  # width for that many, so there the leading few become icon squares and the rest fold into a kebab.
  # Which copy a reader sees is decided per action by `visible`, reading `state.template`.
  @table_template MishkaGervaz.Table.Templates.Table

  # A blogger card ends in labelled text buttons rather than icon squares, so each action carries the
  # whole button: the shared shape, then its own colour. `MishkaCmsCoreWeb.UIAdapters.Admin` draws
  # the icon at 15px, which the design sizes down to 13 — hence the `!`, since `size-*` is set by a
  # base utility too and the runtime compiler's bundle order is not reliable.
  @action_class "inline-flex items-center gap-[5px] bg-transparent p-0 text-[11.5px] " <>
                  "font-semibold transition-colors [&>span:not(.lbl)]:size-[13px]!"

  @edit_action_class @action_class <> " text-[#3a5bc4] hover:text-[#2b48a8]"
  @versions_action_class @action_class <> " text-[#7a5bd0] hover:text-[#5a3fb0]"
  @restore_action_class @action_class <> " text-[#177a53] hover:text-[#0f5e3f]"
  @danger_action_class @action_class <> " text-[#c0473d] hover:text-[#a5352c]"

  # A table row leads with icon-only squares, the shape every runtime table uses; the label still
  # reaches the DOM as `title` and as the `.lbl` span this hides.
  @square "grid size-[30px] flex-none place-items-center rounded-[8px] border transition-colors " <>
            "[&_.lbl]:hidden [&>span:not(.lbl)]:size-[15px]!"

  @square_action @square <>
                   " border-[#ecebe6] bg-[#faf9f6] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"

  @square_danger @square <> " border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"

  # The overflow actions ride in the kebab, each a full-width menu row: icon then label, left aligned.
  @menu_item "flex w-full items-center gap-2.5 rounded-[8px] px-2.5 py-[7px] text-[12px] " <>
               "font-semibold transition-colors [&_.lbl]:flex-1 [&_.lbl]:text-start"

  @menu_versions @menu_item <> " text-[#7a5bd0] hover:bg-[#f4ecfb]"
  @menu_danger @menu_item <> " text-[#c0473d] hover:bg-[#fbeceb]"

  @admin_fields [
    :user_id,
    :display_name,
    :bio,
    :avatar_url,
    :cover_image_url,
    :slug,
    :expertise_areas,
    :social_links,
    :contact_email,
    :can_publish_directly,
    :site_id
  ]

  # Database configuration for bloggers storage with indexing
  postgres do
    table "mishka_blog_bloggers"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
      reference :user, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:user_id]
      index [:can_publish_directly]
    end

    check_constraints do
      check_constraint :slug, "slug_length_check",
        check: "length(slug) >= 1 AND length(slug) <= 255",
        message: dgettext_noop("errors", "Slug must be between 1 and 255 characters.")

      check_constraint :slug, "no_empty_slug",
        check: "slug != ''",
        message: dgettext_noop("errors", "Slug cannot be empty.")

      check_constraint :display_name, "display_name_length",
        check: "length(display_name) >= 1 AND length(display_name) <= 255",
        message: dgettext_noop("errors", "Display name must be between 1 and 255 characters.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_blogger_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_blogger_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived blogger profile'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_blogger_updates();"
      end

      statement :prevent_archived_blogger_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_blogger_updates_trigger
          BEFORE UPDATE ON mishka_blog_bloggers
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_blogger_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_blogger_updates_trigger ON mishka_blog_bloggers;"
      end
    end
  end

  # Soft deletion configuration using archived_at timestamp
  archive do
    exclude_read_actions [
      :archived,
      :get_archived,
      :master_get_archived,
      :master_get,
      :master_archived
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  # Version control configuration for full blogger profile history tracking
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

    mixin {MishkaBlog.Resources.Mixins.PaperTrailMixin, :postgres,
           ["mishka_blog_blogger_versions"]}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "blogger"

    # `:user` is deliberately absent. `public_list`/`public_get`/`public_by_slug` are anonymous by
    # design, and User is reachable through any relationship (`ExtensionInteraction` waves
    # relationship loads past the row policies), so including it published the account's
    # `default_fields` — email, permission_values, site_id — to whoever asked. A public author page
    # renders this resource's own `display_name`, `slug`, `bio` and `avatar_url`; it never needs the
    # account. Admin routes load the user through their own gated actions.
    includes [
      :teams,
      :master_teams,
      :tenant_teams,
      :posts,
      :master_posts,
      :tenant_posts
    ]

    paginated_includes [
      :teams,
      :master_teams,
      :tenant_teams,
      :posts,
      :master_posts,
      :tenant_posts
    ]
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :bloggers
        route "/admin/dashboard/blog/bloggers"
        stream_name :bloggers
      end

      source do
        preload do
          always [:site, :version_count, :follower_count, :post_count, :user]
        end
      end

      columns do
        column :avatar do
          static true
          requires [:avatar_url, :display_name]
          label fn -> dgettext("mishka_gervaz", "Avatar") end

          # A 44px circle plus the cell's own 16px padding either side. Left to the grid's
          # first-column default it would claim 1.7fr and open a gap the width of the name beside it.
          ui do
            width "76px"
          end

          render fn record ->
            assigns = %{avatar_url: record.avatar_url, display_name: record.display_name}

            ~H"""
            <img
              :if={@avatar_url}
              src={@avatar_url}
              alt={@display_name}
              class="size-11 rounded-full bg-[#f4f3ef] overflow-hidden object-cover text-transparent"
            />
            <div
              :if={is_nil(@avatar_url)}
              class="grid size-11 place-items-center rounded-full bg-[#f4f3ef]"
            >
              <.icon name="hero-user" class="size-[18px] text-[#a8a5a0]" />
            </div>
            """
          end
        end

        column :display_name do
          static true
          requires [:id, :display_name, :slug]
          label fn -> dgettext("mishka_gervaz", "Name") end
          sortable true
          sort_field [:display_name]
          visible fn state -> state.template.name() == :table end

          # A name and a slug are both short and fixed-length-ish, so this column is given the
          # smallest share that still fits them; the slack goes to :expertise_areas below, whose
          # chips are the only cell here that actually grows with its content.
          ui do
            width "minmax(170px,1.1fr)"
          end

          render fn record ->
            assigns = %{id: record.id, display_name: record.display_name, slug: record.slug}

            ~H"""
            <div class="min-w-0">
              <div class="truncate text-[13.5px] font-semibold text-[#17161a]">{@display_name}</div>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span class="font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">
                  /{@slug}
                </span>
                <.copy_button
                  id={"blogger-slug-copy-#{@id}"}
                  value={@slug}
                  label={dgettext("mishka_gervaz", "Copy slug")}
                />
              </div>
            </div>
            """
          end
        end

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

        # The chips, the `+N` and its expand/collapse are all the `:tags` type's job — the chip class
        # is the card's own (blogger_card.ex), so the two views draw the same shape.
        column :expertise_areas do
          label fn -> dgettext("mishka_gervaz", "Expertise") end
          visible fn state -> state.template.name() == :table end

          ui do
            type :tags
            width "minmax(180px,1.8fr)"

            extra %{
              max_items: 3,
              badge_class:
                "inline-flex items-center rounded-[7px] bg-[#f4f3ef] px-2 py-[3px] " <>
                  "text-[10.5px] font-semibold text-[#6d6a63]"
            }
          end
        end

        column :stats_info do
          static true
          requires [:post_count, :follower_count, :version_count]
          label fn -> dgettext("mishka_gervaz", "Stats") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(150px,1.2fr)"
          end

          render fn record ->
            assigns = %{
              post_count: record.post_count || 0,
              follower_count: record.follower_count || 0,
              version_count: record.version_count || 0
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-x-[11px] gap-y-1.5 text-[11.5px] font-semibold text-[#8a877f]">
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Posts")}>
                <.icon name="hero-document-text" class="size-[13px] text-[#c3c0b8]" />
                {@post_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Followers")}>
                <.icon name="hero-users" class="size-[13px] text-[#c3c0b8]" />
                {@follower_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Versions")}>
                <.icon name="hero-clock" class="size-[13px] text-[#c3c0b8]" />
                {@version_count}
              </span>
            </div>
            """
          end
        end

        column :can_publish_directly do
          static true
          requires [:can_publish_directly]
          label fn -> dgettext("mishka_gervaz", "Role") end
          visible fn state -> state.template.name() == :table end

          ui do
            type :badge

            extra %{
              colors: %{
                "true" => "bg-[#eef1fc] text-[#4f4bcc]",
                "false" => "bg-[#f4f3ef] text-[#8a877f]"
              },
              labels: %{
                "true" => dgettext_noop("mishka_gervaz", "Publisher"),
                "false" => dgettext_noop("mishka_gervaz", "Contributor")
              },
              default_color: "bg-[#f4f3ef] text-[#8a877f]"
            }
          end
        end
      end

      filters do
        filter :search, :text, fields: [:display_name, :slug, :bio]

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

        filter :can_publish_directly, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Can Publish Directly") end
          end
        end
      end

      row_actions do
        # Every action is listed inline; `visible` decides which copy a reader sees. The card shows
        # them all as text buttons, as the design draws it; the table shows the leading few as icon
        # squares and folds the rest into the kebab so the Actions cell stays legible.
        actions_layout do
          inline [
            :edit,
            :versions,
            :archive,
            :unarchive,
            :permanent_destroy,
            :table_edit,
            :table_archive,
            :table_unarchive
          ]

          dropdown [:blogger_actions]
        end

        action :edit do
          type :edit

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("blogger-form-modal") end

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
            dgettext("mishka_gervaz", "Are you sure you want to archive this blogger?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this blogger?")
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

        action :permanent_destroy do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Are you sure you want to PERMANENTLY delete this blogger? This action cannot be undone!"
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

        action :table_edit do
          type :edit

          visible fn _record, state ->
            state.archive_status == :active and state.template == @table_template
          end

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("blogger-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @square_action
          end
        end

        action :table_archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this blogger?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this blogger?")
          end

          visible fn _record, state ->
            state.archive_status == :archived and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @square_action
          end
        end

        dropdown :blogger_actions do
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

          separator label: dgettext_noop("mishka_gervaz", "Permanent")

          action :menu_permanent_destroy do
            type :permanent_destroy

            confirm dgettext_noop(
                      "mishka_gervaz",
                      "Are you sure you want to PERMANENTLY delete this blogger? This action cannot be undone!"
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
      end

      row do
        selectable true
      end

      realtime do
        prefix "blogger"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "bloggers"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No bloggers found"),
                  icon: "hero-user-circle"

      presentation do
        template MishkaBlogWeb.Templates.BloggerCard
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaBlogWeb.Templates.BloggerCard
        ]
      end
    end

    form do
      identity do
        name :blogger_form
      end

      source do
        preload do
          master [:master_teams]
          tenant [:tenant_teams]
        end
      end

      fields do
        field :site_id, :relation do
          display_field :name
          search_field :name
          mode :search
          restricted true
          show_on :create

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        # A master is offered the chosen site's users and every master, each master marked as one; a
        # site's admin its own site's users only, since only a master links a profile to a master.
        field :user_id, :relation do
          search_field :email
          mode :search
          required true
          show_on :create
          depends_on :site_id

          display_field fn
            %{site_id: nil, email: email} ->
              dgettext("mishka_gervaz", "%{email} (master)", email: to_string(email))

            %{email: email} ->
              to_string(email)
          end

          load fn query, state ->
            if state.master_user? do
              site_id = Map.get(state.field_values, :site_id)
              Ash.Query.filter(query, site_id == ^site_id or is_nil(site_id))
            else
              Ash.Query.filter_input(query, %{site_id: Map.get(state.current_user, :site_id)})
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "User") end
          end
        end

        field :display_name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Display Name") end
            placeholder fn -> dgettext("mishka_gervaz", "Blogger display name") end
          end
        end

        field :slug do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
            placeholder fn -> dgettext("mishka_gervaz", "blogger-slug") end
          end
        end

        field :contact_email do
          ui do
            label fn -> dgettext("mishka_gervaz", "Contact Email") end
            placeholder fn -> dgettext("mishka_gervaz", "blogger@example.com") end
          end
        end

        field :can_publish_directly, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Can Publish Directly") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Enforcing this when a post is published is on our roadmap."
              )
            end
          end
        end

        field :team_ids, :relation do
          virtual true
          resource MishkaBlog.Team
          display_field :name
          search_field :name
          mode :search_multi
          depends_on :site_id

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            Ash.Query.filter_input(query, %{site_id: site_id})
          end

          derive_value fn record ->
            teams =
              cond do
                is_list(Map.get(record, :master_teams)) -> record.master_teams
                is_list(Map.get(record, :tenant_teams)) -> record.tenant_teams
                is_list(Map.get(record, :teams)) -> record.teams
                true -> []
              end

            Enum.map(teams, &to_string(&1.id))
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Teams") end
          end
        end

        field :bio, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Bio") end
            rows 3
          end
        end

        field :avatar_url, :text do
          ui do
            label fn -> dgettext("mishka_gervaz", "Avatar") end
            placeholder fn -> dgettext("mishka_gervaz", "https://example.com/avatar.jpg") end
            extra %{dir: "ltr", media: :images, folder: "blog"}
          end
        end

        field :cover_image_url, :text do
          ui do
            label fn -> dgettext("mishka_gervaz", "Cover Image") end
            placeholder fn -> dgettext("mishka_gervaz", "https://example.com/cover.jpg") end
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

        field :expertise_areas, :string_list do
          ui do
            label fn -> dgettext("mishka_gervaz", "Expertise Areas") end
            placeholder fn -> dgettext("mishka_gervaz", "e.g. Elixir, Phoenix, LiveView") end
          end
        end

        # The column says exactly what a row is — `platform` and `url`, both required — so the form
        # can say it too. Asked for as JSON, adding one link meant typing
        # `[{"platform": "github", "url": "https://github.com/user"}]` by hand, brackets and quotes
        # included, and a misspelt key was stored without complaint.
        field :social_links, :key_list do
          options [
            [
              name: :platform,
              type: :text,
              label: dgettext_noop("mishka_gervaz", "Platform"),
              placeholder: dgettext_noop("mishka_gervaz", "e.g. github")
            ],
            [
              name: :url,
              type: :text,
              label: dgettext_noop("mishka_gervaz", "URL"),
              placeholder: dgettext_noop("mishka_gervaz", "https://github.com/user")
            ]
          ]

          ui do
            label fn -> dgettext("mishka_gervaz", "Social Links") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add Link") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [
            :site_id,
            :user_id,
            :display_name,
            :slug,
            :contact_email,
            :can_publish_directly,
            :team_ids
          ]

          ui do
            columns 2
            class ""
          end
        end

        group :content do
          fields [:bio]

          ui do
            columns 1
            class ""
          end
        end

        group :media do
          fields [:avatar_url, :cover_image_url, :share_card]

          ui do
            columns 2
            class ""
          end
        end

        group :data do
          fields [:expertise_areas, :social_links]

          ui do
            columns 2
            class ""
          end
        end
      end

      # For `text_input/1` only — the adapter falls back to Tailwind for everything else. It is what
      # turns the pictures' `extra %{media: :images}` into a field filled from the media library.
      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        # While a profile is added, its slug follows the display name until the author types one.
        on_validate fn params, state ->
          MishkaCmsCore.Runtime.Helpers.follow_slug(params, state, :display_name)
        end

        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :display_name, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :slug, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :bio, :string, derives: "sanitize(basic_html) validate(optional=[string])"

    field :avatar_url, :string, derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :cover_image_url, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :expertise_areas, {:array, :string},
      derives: "sanitize(each=[trim], reject_empty, uniq) validate(list)"

    field :social_links, {:array, :map}, derives: "validate(list)"

    field :contact_email, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=255])"

    field :can_publish_directly, :boolean, derives: "validate(boolean)"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields. `can_publish_directly` is a moderation setting — which accounts skip review
    # — not part of the public profile.
    field_policy [:version_count, :latest_version, :recent_versions, :can_publish_directly] do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # All other fields are publicly accessible
    field_policy :* do
      authorize_if always()
    end
  end

  # WHO may read which FIELD, as opposed to which row. Ash requires that once any field policy
  # exists, every field is covered — hence the `:*` catch-all — and that ALL policies matching a
  # field pass, so the specific rule below is the one that governs `author_email`.
  field_policies do
    field_policy :author_email do
      description "The account behind a public author page is admin-only"

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end

    # Everything else is the author page itself — display_name, slug, bio, avatar_url.
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

      argument :team_ids, {:array, :uuid} do
        description "List of team IDs to assign this blogger to"
      end

      validate present([:user_id, :display_name, :slug])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:team_ids, :tenant_teams,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      description "Creates blogger profile for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      argument :team_ids, {:array, :uuid} do
        description "List of team IDs to assign this blogger to"
      end

      validate present([:user_id, :display_name, :slug, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:team_ids, :tenant_teams,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      description "Creates blogger profile for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      argument :team_ids, {:array, :uuid} do
        description "List of team IDs to assign this blogger to (replaces existing)"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived blogger profile. Please unarchive it first."
                )
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:team_ids, :tenant_teams,
               type: :append_and_remove,
               on_no_match: :error,
               on_lookup: :relate
             )

      description "Updates blogger profile for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates blogger profile for master users - requires nil tenant context, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass

      argument :team_ids, {:array, :uuid} do
        description "List of team IDs to assign this blogger to (replaces existing)"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # Records are related within the record's own site, whoever the caller is.
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived blogger profile. Please unarchive it first."
                )
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      change manage_relationship(:team_ids, :tenant_teams,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    read :by_user do
      description "Reads blogger profile by user_id within current tenant context"
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :by_slug do
      description "Reads blogger profile by slug within current tenant context"
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_by_slug do
      multitenancy :bypass
      description "Reads blogger profile by slug system-wide (master users only)"
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_by_user do
      multitenancy :bypass
      description "Reads blogger profile by user_id system-wide (master users only)"
      argument :user_id, :uuid, allow_nil?: false
      filter expr(user_id == ^arg(:user_id))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_read do
      description "Reads all blogger profiles system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single blogger profile by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived blogger profiles within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived blogger profile for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived blogger profile for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived blogger profiles system-wide, bypassing tenant filtering"
    end

    read :public_list do
      description "Public endpoint to list all active (non-archived) bloggers (no authentication required)"
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :blogger}
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      filter expr(is_nil(archived_at))

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    # A PROFILE AS A COMMENT NAMES ITS AUTHOR — `MishkaBlog.Comment.author_profile`. That
    # relationship keeps it to the comment's own site, so this read needs no tenant of its own, and a
    # master reading comments with none still gets their authors' names.
    read :comment_author do
      description "An active blogger profile, as a comment names its author on the comment's own site"
      multitenancy :bypass
      filter expr(is_nil(archived_at))
    end

    read :public_get do
      description "Public endpoint to get a single active (non-archived) blogger by ID (no authentication required)"
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :blogger}
      filter expr(is_nil(archived_at))
      get? true
    end

    read :public_by_slug do
      description "Public endpoint to get a blogger by slug (no authentication required)"
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :blogger}
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      argument :slug, :string, allow_nil?: false
      filter expr(slug == ^arg(:slug) and is_nil(archived_at))
      get? true
    end

    update :assign_teams do
      description "Replaces blogger's team memberships with the provided list of team IDs"
      accept []
      require_atomic? false

      argument :team_ids, {:array, :uuid} do
        allow_nil? false
        description "List of team IDs to assign this blogger to"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:team_ids, :tenant_teams,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_team do
      description "Adds blogger to a single team"
      accept []
      require_atomic? false

      argument :team_id, :uuid do
        allow_nil? false
        description "Team ID to add this blogger to"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:team_id, :tenant_teams, type: :append, on_no_match: :error)
    end

    update :remove_team do
      description "Removes blogger from a single team"
      accept []
      require_atomic? false

      argument :team_id, :uuid do
        allow_nil? false
        description "Team ID to remove this blogger from"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:team_id, :tenant_teams, type: :remove)
    end

    destroy :destroy do
      description "Soft deletes blogger profile by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Blogger profile is already archived.")}
        else
          :ok
        end
      end
    end

    destroy :master_destroy do
      description "Soft deletes blogger profile by archiving (master users) - requires nil tenant context"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Blogger profile is already archived.")}
        else
          :ok
        end
      end
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :archived

      description "Restores archived blogger profile (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived blogger profile (master users) - requires nil tenant context"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "Blogger profile is not archived.")
      end

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Permanently removes blogger profile and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes blogger profile and version history from database (master users) - irreversible and extremely dangerous"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    # VERSION MANAGEMENT - Read Actions

    read :get_with_versions do
      get? true
      description "Gets a single blogger with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.Blogger.Version
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
      description "Gets a single blogger with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.Blogger.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a blogger with pagination (tenant users)"

      argument :blogger_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        blogger_id = Ash.Query.get_argument(query, :blogger_id)

        # First verify the blogger belongs to the tenant
        case Ash.get(MishkaBlog.Blogger, blogger_id, Ash.Scope.to_opts(context)) do
          {:ok, _blogger} ->
            query
            |> Ash.Query.filter(id == ^blogger_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaBlog.Blogger.Version
                |> Ash.Query.new()
            )

          _ ->
            # Return empty results for cross-tenant access
            Ash.Query.filter(query, false)
        end
      end
    end

    read :master_list_versions do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "List all versions for a blogger with pagination (master users)"

      argument :blogger_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        blogger_id = Ash.Query.get_argument(query, :blogger_id)

        query
        |> Ash.Query.filter(id == ^blogger_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaBlog.Blogger.Version
            |> Ash.Query.new()
        )
      end
    end

    # VERSION MANAGEMENT - Restore Actions

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the blogger profile to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived blogger profile. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.Blogger.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "blogger profile")}
    end

    action :restore_version_api, :struct do
      description "Restores blogger profile from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaBlog.Blogger

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        blogger_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaBlog.Blogger, blogger_id, Ash.Scope.to_opts(context, action: :read))
        |> case do
          {:ok, blogger} when not is_nil(blogger) ->
            if is_nil(blogger.archived_at) do
              tenant = blogger.site_id

              blogger
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
                         "Cannot restore version of archived blogger profile. Please unarchive it first."
                       )
                   )
                 ]
               )}
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.Blogger)}
        end
      end
    end

    update :master_restore_version do
      description "Restores blogger profile from a specific version in history (master users)"
      accept []
      require_atomic? false
      multitenancy :bypass

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived blogger profile. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.Blogger.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "blogger profile")}
    end

    action :master_restore_version_api, :struct do
      description "Restores blogger profile from a specific version in history (master users - API)"
      constraints instance_of: MishkaBlog.Blogger

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        blogger_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(
          MishkaBlog.Blogger,
          blogger_id,
          Ash.Scope.to_opts(context, action: :master_get, tenant: nil)
        )
        |> case do
          {:ok, blogger} when not is_nil(blogger) ->
            if is_nil(blogger.archived_at) do
              blogger
              |> Ash.Changeset.for_update(
                :master_restore_version,
                %{version_id: version_id},
                Ash.Scope.to_opts(context, tenant: nil)
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
                         "Cannot restore version of archived blogger profile. Please unarchive it first."
                       )
                   )
                 ]
               )}
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.Blogger)}
        end
      end
    end

    # VERSION MANAGEMENT - Preview Actions

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaBlog.Blogger

      argument :blogger_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :blogger_id,
           version: MishkaBlog.Blogger.Version,
           fields: List.delete(@admin_fields, :site_id),
           label: dgettext_noop("errors", "blogger profile")}
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaBlog.Blogger

      argument :blogger_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :blogger_id,
           version: MishkaBlog.Blogger.Version,
           fields: List.delete(@admin_fields, :site_id),
           master: true,
           label: dgettext_noop("errors", "blogger profile")}
    end
  end

  # Authorization policies for blogger profile access
  policies do
    # Allow public access to view active (non-archived) bloggers
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    bypass action(:public_by_slug) do
      authorize_if always()
    end

    # Only through a comment's `author_profile`, which keeps it to the comment's site.
    bypass action(:comment_author) do
      authorize_if accessing_from(MishkaBlog.Comment, :author_profile)
    end

    # Read directly it crosses every site, so only a master may.
    policy action(:comment_author) do
      authorize_if actor_attribute_equals(:site_id, nil)
    end

    # Admin access for all operations
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
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
    prefix "blogger"

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
    publish :master_restore_version, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # A blogger profile names a user of its own site, or a master — and a master only when a master or
  # the system writes it: a site's admin, whatever it holds, links a profile only to its own site's
  # users. Asked when the action runs, of the actor it runs as, and only when the id changes.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :user_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "user"),
              shared?: :master,
              read_action: :related},
             where: [changing(:user_id)],
             before_action?: true
  end

  # Multi-tenancy configuration - blogger profiles are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Blogger profiles are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :display_name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Public display name of the blogger"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the blogger profile"
    end

    attribute :bio, :string do
      allow_nil? true
      public? true
      description "Biography or description text for the blogger"
    end

    attribute :avatar_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "URL of the blogger's profile image"
    end

    attribute :cover_image_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "URL of the blogger's cover/banner image"
    end

    attribute :expertise_areas, {:array, :string} do
      default []
      public? true
      description "Array of expertise topics or areas the blogger specializes in"
    end

    attribute :social_links, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      platform: [
                        type: :string,
                        allow_nil?: false
                      ],
                      url: [
                        type: :string,
                        allow_nil?: false
                      ]
                    ]
                  ]

      description "Social media URLs and platform identifiers"
    end

    attribute :contact_email, :string do
      allow_nil? true
      public? true
      constraints max_length: 255, trim?: true
      description "Public contact email address for the blogger"
    end

    attribute :can_publish_directly, :boolean do
      default false
      public? true
      description "Whether the blogger can publish posts without approval"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this blogger profile belongs to"
    end

    belongs_to :user, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? false
      public? true
      domain MishkaCmsCore.Accounts
      description "The user account associated with this blogger profile"
    end

    # Relationship - for public with tenant
    many_to_many :teams, MishkaBlog.Team do
      public? true
      description "Teams this blogger is a member of (public access)"
      through MishkaBlog.TeamMember
      source_attribute_on_join_resource :blogger_id
      destination_attribute_on_join_resource :team_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_teams, MishkaBlog.Team do
      public? true
      description "Teams this blogger is a member of (tenant admin access)"
      through MishkaBlog.TeamMember
      source_attribute_on_join_resource :blogger_id
      destination_attribute_on_join_resource :team_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_teams, MishkaBlog.Team do
      public? true
      description "Teams this blogger is a member of (master admin access, bypass tenant)"
      through MishkaBlog.TeamMember
      source_attribute_on_join_resource :blogger_id
      destination_attribute_on_join_resource :team_id
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public with tenant
    many_to_many :posts, MishkaBlog.BlogPost do
      public? true
      description "Blog posts authored or co-authored by this blogger (public access)"
      through MishkaBlog.PostBlogger
      source_attribute_on_join_resource :blogger_id
      destination_attribute_on_join_resource :post_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_posts, MishkaBlog.BlogPost do
      public? true
      description "Blog posts authored or co-authored by this blogger (tenant admin access)"
      through MishkaBlog.PostBlogger
      source_attribute_on_join_resource :blogger_id
      destination_attribute_on_join_resource :post_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_posts, MishkaBlog.BlogPost do
      public? true

      description "Blog posts authored or co-authored by this blogger (master admin access, bypass tenant)"

      through MishkaBlog.PostBlogger
      source_attribute_on_join_resource :blogger_id
      destination_attribute_on_join_resource :post_id
      read_action :read_any

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :followers, MishkaBlog.BloggerFollower do
      public? true
      destination_attribute :blogger_id
      description "Users following this blogger"
    end

    # Loaded through `:sorted_versions` as whoever runs the read. A version query handed to a load
    # is left unbuilt (`Ash.Query.new/1`) so that this action builds it for that reader.
    has_many :sorted_versions, MishkaBlog.Blogger.Version do
      public? true
      destination_attribute :version_source_id
      read_action :sorted_versions
      description "All versions of this blogger profile sorted by insertion date descending"
    end
  end

  calculations do
    calculate :author_email, :string, expr(user.email) do
      public? true

      description """
      The account email behind this blogger, for admin surfaces only — gated by the field policy
      below. It is deliberately NOT a `default_field`: it has to be asked for
      (`?fields[blogger]=author_email`), so no ordinary payload carries it by accident.
      """
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaBlog.Blogger.Version
      description "Returns the most recent version for the blogger profile"

      calculation fn records, context ->
        blogger_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^blogger_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn blogger ->
          Map.get(versions_map, blogger.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaBlog.Blogger.Version]

      description "Returns the 10 most recent versions for the blogger profile in descending order by insertion date"

      calculation fn records, context ->
        blogger_ids = Enum.map(records, & &1.id)

        versions_map =
          MishkaBlog.Blogger.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^blogger_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.Query.limit(10)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn blogger ->
          Map.get(versions_map, blogger.id, [])
        end)
      end
    end
  end

  aggregates do
    count :follower_count, :followers do
      public? true
      authorize? false
    end

    count :version_count, :sorted_versions do
      public? true
      multitenancy :bypass
    end

    count :post_count, :posts do
      public? true
      authorize? false
      multitenancy :bypass
    end
  end

  identities do
    identity :unique_slug_per_site, [:slug, :site_id] do
      description "Ensures blogger slugs are unique within each site for clear identification"
      message dgettext_noop("errors", "Blogger slug must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_user_per_site, [:user_id, :site_id] do
      description "Ensures each user has only one blogger profile per site"
      message dgettext_noop("errors", "User already has a blogger profile in this site.")
      all_tenants? true
      nils_distinct? false
    end
  end
end
