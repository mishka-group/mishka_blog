# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Collection do
  @moduledoc """
  Manages blog post collections in the MishkaBlog plugin with full versioning support.

  This resource represents hierarchical collections that can organize blog posts.
  Each collection belongs to a specific site and can have parent-child relationships
  for nested organization. The resource supports various statuses (active, archived, draft)
  with metadata tracking including SEO tags, Schema.org structured data, and display ordering.

  Collections feature full version control through PaperTrail integration, tracking all changes
  with snapshot-based history and the ability to restore previous versions. The resource
  implements soft deletion via archival and provides comprehensive metadata management
  including SEO optimization and structured data support.

  Database-level constraints ensure data integrity with slug validation and prevention
  of modifications to archived collections. Multi-tenant isolation ensures collections
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

  import Phoenix.Component, only: [sigil_H: 2, link: 1]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  import MishkaGervaz.UIAdapters.Tailwind, only: [copy_button: 1]
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # The card's actions read as text beside their icon rather than as buttons — the design gives them the
  # card's top-right corner, where a row of squares would crowd the folder tile.
  @versions_action_class "inline-flex items-center gap-[5px] text-[11.5px] font-semibold " <>
                           "text-[#7a5bd0] transition-colors hover:text-[#5a3fb0]"

  @edit_action_class "inline-flex items-center gap-[5px] text-[11.5px] font-semibold " <>
                       "text-[#5c5a54] transition-colors hover:text-[#4f4bcc]"

  @danger_action_class "inline-flex items-center gap-[5px] text-[11.5px] font-semibold " <>
                         "text-[#c0473d] transition-colors hover:text-[#a5352c]"

  @restore_action_class "inline-flex items-center gap-[5px] text-[11.5px] font-semibold " <>
                          "text-[#177a53] transition-colors hover:text-[#0f5c3e]"

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
    :parent_collection_id,
    :status,
    :schema,
    :seo_tags,
    :permissions,
    :featured,
    :display_order,
    :language,
    :language_group_id,
    :site_id
  ]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for collections storage with indexing
  postgres do
    table "mishka_blog_collections"
    repo @repo

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:status]
      index [:featured]
      index [:display_order]
      index [:parent_collection_id]
      index [:language]
      index [:language_group_id]
    end

    check_constraints do
      check_constraint :slug, "slug_length_check",
        check: "length(slug) >= 1 AND length(slug) <= 255",
        message: dgettext_noop("errors", "Slug must be between 1 and 255 characters.")

      check_constraint :slug, "no_empty_slug",
        check: "slug != ''",
        message: dgettext_noop("errors", "Slug cannot be empty.")

      check_constraint :display_order, "display_order_positive",
        check: "display_order >= 0",
        message: dgettext_noop("errors", "Display order must be non-negative.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_collection_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_collection_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived collection'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_collection_updates();"
      end

      statement :prevent_archived_collection_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_collection_updates_trigger
          BEFORE UPDATE ON mishka_blog_collections
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_collection_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_collection_updates_trigger ON mishka_blog_collections;"
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

  # Version control configuration for full collection history tracking
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

    mixin {MishkaBlog.Resources.Mixins.CollectionPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "collection"

    includes [:posts, :master_posts, :tenant_posts]

    paginated_includes [:posts, :master_posts, :tenant_posts]
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :collections
        route "/admin/dashboard/blog/collections"
        stream_name :collections
      end

      source do
        # The sibling editions belong here rather than in the `on_load` hook: the hook only runs for the
        # list read, and a single-row re-read — which is what selecting a card does — would come back
        # without them, so the card's language row would vanish the moment it was ticked.
        preload do
          always [:site, :version_count, :post_count]
          tenant [:parent_collection, :language_variants]

          master master_parent_collection: :parent_collection,
                 master_language_variants: :language_variants
        end
      end

      columns do
        # The slug used to be a column of its own, which cost the row a full track to repeat what the
        # name already says. It rides under the name instead, as it does on every other blog table.
        column :name do
          static true
          requires [:id, :name, :slug]
          label fn -> dgettext("mishka_gervaz", "Name") end
          sortable true
          sort_field [:name]

          ui do
            width "minmax(180px,1.3fr)"
          end

          render fn record ->
            assigns = %{id: record.id, name: record.name, slug: record.slug}

            ~H"""
            <div class="min-w-0">
              <.link
                navigate={MishkaBlogWeb.Templates.CollectionCard.posts_path(%{id: @id})}
                class="block truncate text-[13.5px] font-semibold text-[#17161a] transition-colors hover:text-[#4f4bcc]"
              >
                {@name}
              </.link>
              <div class="mt-[2px] flex items-center gap-[5px]">
                <span class="truncate font-['Space_Grotesk'] text-[11px] font-medium text-[#a8a5a0]">
                  /{@slug}
                </span>
                <.copy_button id={"collection-slug-copy-#{@id}"} value={@slug} label={gettext("Copy slug")} />
              </div>
            </div>
            """
          end
        end

        # Every collection's description opens with the same boilerplate, so an un-clamped cell grew
        # the row to six lines of it. Two lines is enough to tell them apart; the rest is the card's.
        column :description do
          static true
          requires [:description]
          label fn -> dgettext("mishka_gervaz", "Description") end

          ui do
            width "minmax(190px,2fr)"
          end

          render fn record ->
            assigns = %{description: record.description}

            ~H"""
            <p
              :if={@description}
              class="line-clamp-2 text-[12.5px] leading-[1.5] text-[#6d6a63]"
              title={@description}
            >
              {@description}
            </p>
            <span :if={is_nil(@description)} class="text-[12px] font-medium text-[#a8a5a0]">{gettext("—")}</span>
            """
          end
        end

        # The same three chips the card draws (`MishkaBlogWeb.Templates.CollectionCard`), in the
        # `:badge` type's shape rather than hand-written, so the row matches every other table.
        column :status do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Status") end

          ui do
            type :badge
            width "minmax(105px,0.85fr)"

            extra %{
              colors: %{
                "active" => "bg-[#e6f6ee] text-[#177a53]",
                "draft" => "bg-[#fbf1df] text-[#a5691a]",
                "archived" => "bg-[#fbe9e7] text-[#b3433a]"
              },
              labels: %{
                "active" => dgettext_noop("mishka_gervaz", "Active"),
                "draft" => dgettext_noop("mishka_gervaz", "Draft"),
                "archived" => dgettext_noop("mishka_gervaz", "Archived")
              },
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
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

        # Posts, versions, the language chip and the featured star share one cell exactly as they do
        # on the posts table, so a reader crossing between the two pages reads the same row of counts.
        column :stats_info do
          static true

          requires [
            :id,
            :status,
            :archived_at,
            :post_count,
            :version_count,
            :language,
            :language_group_id,
            :language_variants,
            :master_language_variants,
            :featured
          ]

          label fn -> dgettext("mishka_gervaz", "Stats") end
          visible fn state -> state.template.name() == :table end

          # Wide enough that the featured star still lands on the counts' own line — a featured row
          # wrapping to two lines when the row beside it does not reads as a rendering fault.
          ui do
            width "minmax(160px,1.3fr)"
          end

          render fn record ->
            assigns = %{
              record: record,
              post_count: record.post_count || 0,
              version_count: record.version_count || 0,
              language: record.language,
              featured: record.featured,
              editions: MishkaBlogWeb.Templates.EditionChips.editions(record),
              accent: MishkaCmsCore.LanguageAccent.of(record)
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-x-[11px] gap-y-1.5 text-[11.5px] font-semibold text-[#8a877f]">
              <span class="inline-flex items-center gap-[5px]" title={gettext("Posts")}>
                <.icon name="hero-document-text" class="size-[13px] text-[#c3c0b8]" />
                {@post_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={gettext("Versions")}>
                <.icon name="hero-clock" class="size-[13px] text-[#c3c0b8]" />
                {@version_count}
              </span>
              <MishkaBlogWeb.Templates.EditionChips.inline
                id={"collection-editions-#{@record.id}"}
                record={@record}
                editions={@editions}
                accent={@accent}
              />
              <span
                :if={@language && @editions == []}
                class="rounded-[5px] bg-[#f4f3ee] px-[6px] py-[2px] text-[10px] font-bold uppercase tracking-[0.04em] text-[#6d6a63]"
                title={gettext("Language")}
              >
                {@language}
              </span>
              <span :if={@featured} title={gettext("Featured")}>
                <.icon name="hero-star-solid" class="size-[13px] text-[#d9a520]" />
              </span>
            </div>
            """
          end
        end

        column :parent_info do
          static true
          requires [:parent_collection_id, :parent_collection]
          label fn -> dgettext("mishka_gervaz", "Parent") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(120px,1fr)"
          end

          render fn record ->
            parent_name =
              if record.parent_collection, do: record.parent_collection.name, else: nil

            assigns = %{parent_id: record.parent_collection_id, parent_name: parent_name}

            ~H"""
            <span
              :if={@parent_id}
              class="inline-flex min-w-0 items-center gap-[5px] rounded-[7px] bg-[#f4f3ef] px-2 py-[3px] text-[10.5px] font-semibold text-[#6d6a63]"
              title={@parent_name}
            >
              <.icon name="hero-folder" class="size-[12px] shrink-0 text-[#a8a5a0]" />
              <span class="truncate">{@parent_name}</span>
            </span>
            <span :if={is_nil(@parent_id)} class="text-[12px] font-medium text-[#a8a5a0]">{gettext("—")}</span>
            """
          end
        end
      end

      filters do
        filter :search, :text do
          fields [:name, :slug, :description]

          ui do
            label fn -> dgettext("mishka_gervaz", "Search") end
            placeholder fn -> dgettext("mishka_gervaz", "Search collections…") end
          end
        end

        filter :site_id, :relation do
          mode :search_multi
          display_field :name
          search_field :name
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
              {dgettext("mishka_gervaz", "Draft"), :draft}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :language, :select do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_blog_collections WHERE language IS NOT NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} -> Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)
              _ -> []
            end
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Languages")
            label fn -> dgettext("mishka_gervaz", "Language") end
          end
        end

        filter :featured, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured only") end
          end
        end
      end

      row_actions do
        # Every action not living in the kebab has to be named here, card copy and table copy alike;
        # `visible` is what picks between them at render time.
        actions_layout do
          inline [
            :versions,
            :edit,
            :archive,
            :unarchive,
            :permanent_destroy,
            :table_edit,
            :table_archive,
            :table_unarchive
          ]

          dropdown [:collection_actions]
        end

        action :table_edit do
          type :event
          event "show_edition"

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
            dgettext("mishka_gervaz", "Are you sure you want to archive this collection?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this collection?")
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

        dropdown :collection_actions do
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
                      "Are you sure you want to PERMANENTLY delete this collection? This action cannot be undone!"
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

        # Editing goes through the same modal a language chip opens, so a collection has one edit path
        # whichever language you reached it by. `:event` rather than `:edit` because the page owns that
        # modal and needs the record id to load the edition first.
        action :edit do
          type :event
          event "show_edition"

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @edit_action_class
          end
        end

        action :archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this collection?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this collection?")
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
                    "Are you sure you want to PERMANENTLY delete this collection? This action cannot be undone!"
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

        # A featured collection is drawn with a gold edge rather than a badge — the card's chip row is
        # already carrying its status, its site and its languages. `possible` is what puts these classes
        # in front of the runtime CSS compiler, which only emits a class it can read literally.
        class do
          possible ["border-[#e0b64a]!", "ring-1", "ring-[#f0e2c4]"]

          apply fn
            %{featured: true} -> ["border-[#e0b64a]!", "ring-1", "ring-[#f0e2c4]"]
            _collection -> nil
          end
        end
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected collections?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected collections?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected collections? This cannot be undone."
            ),
          visible: :archived
      end

      realtime do
        prefix "collection"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "collections"
        max_filter_length 500
      end

      events do
        bulk_action MishkaCmsCore.LanguageEditions.BulkActionHandler
      end

      hooks do
        # One row per collection, not one per translation — see `MishkaCmsCore.LanguageEditions`. This
        # belongs here rather than on the read action because only a hook runs late enough to see
        # whether a search is active, and a search must reach every language. The siblings themselves
        # are preloaded above, so every read path carries them, not just this one. A live update is
        # asked of the same read, and `on_realtime` redraws a translation's master.
        on_load fn query, state ->
          {:cont, MishkaCmsCore.LanguageEditions.scope_to_masters(query, state)}
        end

        on_realtime fn notification, socket ->
          MishkaCmsCore.LanguageEditions.on_realtime(notification, socket)
        end

        # A delete refused because the collection's translations are live answers with an alert that
        # offers to archive — or delete for good — those translations at once. See
        # `MishkaCmsCore.LanguageEditions`.
        on_row_action_error [:delete, :permanent_destroy],
                            &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_error [:archive, :permanent_destroy],
                             &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_success [:archive, :permanent_destroy],
                               &MishkaCmsCore.LanguageEditions.on_delete_refused/3
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No collections found"),
                  icon: "hero-folder"

      presentation do
        template MishkaBlogWeb.Templates.CollectionCard
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaBlogWeb.Templates.CollectionCard
        ]
      end
    end

    form do
      identity do
        name :collection_form
      end

      fields do
        field :name do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Name") end
            placeholder fn -> dgettext("mishka_gervaz", "Collection name") end
          end
        end

        field :slug do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
            placeholder fn -> dgettext("mishka_gervaz", "collection-slug") end
          end
        end

        field :status do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Active"), :active},
              {dgettext("mishka_gervaz", "Draft"), :draft}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        field :language, :combobox do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_blog_collections WHERE language IS NOT NULL ORDER BY language"
                 ) do
              {:ok, %{rows: rows}} -> Enum.map(rows, fn [lang] -> {String.upcase(lang), lang} end)
              _ -> []
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language") end
            placeholder fn -> dgettext("mishka_gervaz", "en, fa, ar, ...") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Add this code under Settings → Languages as well, or its URL answers 404."
              )
            end
          end
        end

        # Only the groups of the site the collection is on. A master reads every site's rows, and a group on
        # another site is one this collection's editions would never be listed or checked with.
        field :language_group_id, :relation do
          value_field :language_group_id
          display_field fn record -> "#{record.name} (#{record.language})" end
          search_field :name
          mode :search
          depends_on :site_id
          include_nil fn -> dgettext("mishka_gervaz", "New Language Group (auto-generate)") end

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            # A group is offered once, by its first edition, and only while that edition is live.
            query
            |> Ash.Query.filter_input(%{site_id: site_id})
            |> Ash.Query.filter(language_group_id == id)
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Language Group") end
          end
        end

        field :parent_collection_id, :relation do
          display_field :name
          search_field :name
          mode :search
          depends_on :site_id
          include_nil fn -> dgettext("mishka_gervaz", "No Parent (Top Level)") end

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            Ash.Query.filter_input(query, %{site_id: site_id})
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Parent Collection") end
          end
        end

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

        field :display_order do
          ui do
            label fn -> dgettext("mishka_gervaz", "Display Order") end
          end
        end

        field :featured do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured") end
          end
        end

        field :description, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Description") end
            rows 3
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

        field :seo_tags, :nested do
          ui do
            label fn -> dgettext("mishka_gervaz", "SEO Tags") end
            add_label fn -> dgettext("mishka_gervaz", "+ Add SEO Tag") end
            remove_label fn -> dgettext("mishka_gervaz", "Remove") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "A title replaces the page's title; meta and link tags each replace the default with the same name. A value may name a variable such as {{page.title}}."
              )
            end
          end

          nested_field :tag, :select do
            options [{"title", "title"}, {"meta", "meta"}, {"link", "link"}]

            ui do
              label fn -> dgettext("mishka_gervaz", "Tag") end
              placeholder fn -> dgettext("mishka_gervaz", "Choose a tag") end
            end
          end

          nested_field :attrs, :json do
            ui do
              label fn -> dgettext("mishka_gervaz", "Attributes") end
              placeholder ~s({"name": "description", "property": "og:title"})
            end
          end

          nested_field :content, :textarea do
            ui do
              label fn -> dgettext("mishka_gervaz", "Content") end
              placeholder fn -> dgettext("mishka_gervaz", "Tag content text...") end
              rows 3
            end
          end
        end

        field :schema do
          ui do
            label fn -> dgettext("mishka_gervaz", "Schema (JSON)") end
            placeholder ~s([{"@type": "CollectionPage", "name": "My Collection"}])
          end
        end

        # WHO MAY OPEN THE CATEGORY ON ITS PAGE: any of the permission names that exist, stored by
        # name. Empty, it is public. `MishkaBlog.Plugins.PageSeo` answers them, and
        # `MishkaCmsWeb.RuntimeLive` asks for them after the page's own.
        field :permissions, :relation do
          resource MishkaCmsCore.Accounts.Permission
          display_field :name
          search_field :name
          value_field :name
          mode :search_multi
          page_size 15

          ui do
            label fn -> dgettext("mishka_gervaz", "Permissions") end

            description fn ->
              dgettext(
                "mishka_gervaz",
                "Who may open this category: anyone holding one of these. None: everyone."
              )
            end
          end
        end
      end

      groups do
        group :basic_info do
          fields [
            :name,
            :slug,
            :status,
            :language,
            :site_id,
            :language_group_id,
            :parent_collection_id,
            :display_order,
            :featured
          ]

          ui do
            columns 2
            class ""
          end
        end

        group :content do
          fields [:description, :share_card]

          ui do
            columns 1
            class ""
          end
        end

        group :data do
          fields [:seo_tags, :schema, :permissions]

          ui do
            columns 1
            class ""
          end
        end
      end

      # For `text_input/1` only — the adapter falls back to Tailwind for everything else. It is what
      # turns the Share image field's `extra %{share_card: …}` into the card and its Regenerate.
      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        # While a collection is added, its slug follows the name until the author types one.
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
      derives: "sanitize(trim) validate(optional=[string, max_len=2000])"

    field :status, :atom, derives: "validate(atom, enum=Atom[active::archived::draft])"

    field :schema, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :featured, :boolean, derives: "validate(boolean)"
    field :display_order, :integer, derives: "validate(optional=[integer, min_len=0])"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=20, language_code])"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
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

      validate present([:name])
      validate present([:slug])
      validate present([:status])
      validate present([:language])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_collection_id,
                resource: MishkaBlog.Collection,
                message:
                  dgettext_noop(
                    "errors",
                    "Parent collection not found or does not belong to your site."
                  )}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id,
                resource: MishkaBlog.Collection,
                message:
                  dgettext_noop(
                    "errors",
                    "Language group not found or does not belong to your site."
                  )}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      description "Creates collection for tenant users - requires tenant context, auto-assigns site_id and language_group_id for master collections"
    end

    create :master_create do
      validate present([:name])
      validate present([:slug])
      validate present([:status])
      validate present([:language])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      description "Creates collection for master users - bypasses multi-tenancy, requires explicit site_id, auto-assigns language_group_id for master collections"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_collection_id,
                resource: MishkaBlog.Collection,
                message:
                  dgettext_noop(
                    "errors",
                    "Parent collection not found or does not belong to your site."
                  )},
               where: [changing(:parent_collection_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id,
                resource: MishkaBlog.Collection,
                message:
                  dgettext_noop(
                    "errors",
                    "Language group not found or does not belong to your site."
                  )},
               where: [changing(:language_group_id)]

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived collection. Please unarchive it first."
                )
      end

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_collection_id)
        collection_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == collection_id do
          {:error,
           field: :parent_collection_id,
           message: dgettext_noop("errors", "Collection cannot be its own parent.")}
        else
          :ok
        end
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      description "Updates collection for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates collection for master users - bypasses multi-tenancy, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived collection. Please unarchive it first."
                )
      end

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_collection_id)
        collection_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == collection_id do
          {:error,
           field: :parent_collection_id,
           message: dgettext_noop("errors", "Collection cannot be its own parent.")}
        else
          :ok
        end
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])
    end

    read :master_read do
      description "Reads all collections system-wide, bypassing tenant filtering (master users only)"
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
      description "Retrieves single collection by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    # Only a master reads through this with authorization on; see the `:read_any` policy.
    read :read_any do
      multitenancy :bypass
      description "Reads collections bypassing tenant filtering - for relationship loading"
    end

    read :language_variants do
      description "Retrieves all language variants of a collection for hreflang tag generation"
      argument :language_group_id, :uuid, allow_nil?: false
      filter expr(language_group_id == ^arg(:language_group_id))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_language_variants do
      multitenancy :bypass
      description "Retrieves all language variants system-wide (master users only)"
      argument :language_group_id, :uuid, allow_nil?: false
      filter expr(language_group_id == ^arg(:language_group_id))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :public_list do
      description "Public endpoint to list all active collections (no authentication required)"
      filter expr(status == :active)
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :category}

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :public_get do
      description "Public endpoint to get a single active collection by ID (no authentication required)"
      get? true
      filter expr(status == :active)
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :category}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived collections within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived collection for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived collection for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived collections system-wide, bypassing tenant filtering"
    end

    update :assign_posts do
      description "Replaces collection's posts with the provided list of post IDs"
      accept []
      require_atomic? false

      argument :post_ids, {:array, :uuid} do
        allow_nil? false
        description "List of post IDs to assign to this collection"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:post_ids, :tenant_posts,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_post do
      description "Adds a single post to the collection"
      accept []
      require_atomic? false

      argument :post_id, :uuid do
        allow_nil? false
        description "Post ID to add to this collection"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:post_id, :tenant_posts, type: :append, on_no_match: :error)
    end

    update :remove_post do
      description "Removes a single post from the collection"
      accept []
      require_atomic? false

      argument :post_id, :uuid do
        allow_nil? false
        description "Post ID to remove from this collection"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:post_id, :tenant_posts, type: :remove)
    end

    destroy :destroy do
      description "Soft deletes collection by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Collection is already archived.")}
        else
          :ok
        end
      end

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :status, :archived)
             end)
    end

    destroy :master_destroy do
      description "Soft deletes collection by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Collection is already archived.")}
        else
          :ok
        end
      end

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      change before_action(fn changeset, _context ->
               Ash.Changeset.force_change_attribute(changeset, :status, :archived)
             end)
    end

    update :unarchive do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :active)

      change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore

      atomic_upgrade_with :archived

      description "Restores archived collection to active status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived collection to active status (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "Collection is not archived.")
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :active)

      change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      description "Permanently removes collection and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes collection and version history from database (master users) - bypasses multi-tenancy, irreversible and extremely dangerous"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
    end

    read :get_with_versions do
      description "Retrieves collection with paginated version history (tenant users)"
      get? true

      argument :versions_limit, :integer do
        default 20
        allow_nil? true
      end

      argument :versions_offset, :integer do
        default 0
        allow_nil? true
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        limit = Ash.Query.get_argument(query, :versions_limit)
        offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.Collection.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(limit)
            |> Ash.Query.offset(offset)
        )
      end
    end

    read :master_get_with_versions do
      description "Retrieves collection with paginated version history (master users)"
      multitenancy :bypass
      get? true

      argument :versions_limit, :integer do
        default 20
        allow_nil? true
      end

      argument :versions_offset, :integer do
        default 0
        allow_nil? true
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        limit = Ash.Query.get_argument(query, :versions_limit)
        offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.Collection.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(limit)
            |> Ash.Query.offset(offset)
        )
      end
    end

    read :list_versions do
      description "Lists all versions for a collection (tenant users)"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      argument :collection_id, :uuid do
        allow_nil? false
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      filter expr(id == ^arg(:collection_id))

      prepare fn query, context ->
        versions_query =
          MishkaBlog.Collection.Version
          |> Ash.Query.new()

        Ash.Query.load(query, sorted_versions: versions_query)
      end
    end

    read :master_list_versions do
      description "Lists all versions for a collection (master users)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      argument :collection_id, :uuid do
        allow_nil? false
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      filter expr(id == ^arg(:collection_id))

      prepare fn query, context ->
        versions_query =
          MishkaBlog.Collection.Version
          |> Ash.Query.new()

        Ash.Query.load(query, sorted_versions: versions_query)
      end
    end

    update :restore_version do
      accept []
      description "Restores collection to a specific version state (tenant users)"
      require_atomic? false
      transaction? true

      argument :version_id, :uuid do
        allow_nil? false
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.Collection.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "collection")}
    end

    action :restore_version_api, :struct do
      description "Restores collection to a specific version (tenant API users)"
      constraints instance_of: MishkaBlog.Collection

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(MishkaBlog.Collection, id, Ash.Scope.to_opts(context)) do
          {:ok, record} when not is_nil(record) ->
            record
            |> Ash.Changeset.for_update(
              :restore_version,
              %{version_id: version_id},
              Ash.Scope.to_opts(context)
            )
            |> Ash.update()

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.Collection)}
        end
      end
    end

    update :master_restore_version do
      accept []
      description "Restores collection to a specific version state (master users)"
      require_atomic? false
      transaction? true
      multitenancy :bypass

      argument :version_id, :uuid do
        allow_nil? false
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.Collection.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "collection")}
    end

    action :master_restore_version_api, :struct do
      description "Restores collection to a specific version (master API users)"
      constraints instance_of: MishkaBlog.Collection

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        id = input.arguments.id
        version_id = input.arguments.version_id

        case Ash.get(
               MishkaBlog.Collection,
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
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.Collection)}
        end
      end
    end

    read :preview_version do
      description "Preview a specific version without modifying the collection (tenant users)"
      get? true

      argument :collection_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      filter expr(id == ^arg(:collection_id))

      prepare fn query, context ->
        version_id = Ash.Query.get_argument(query, :version_id)

        Ash.Query.after_action(query, fn _query, results ->
          MishkaBlog.Resources.Changes.RestoreVersion.preview(
            results,
            MishkaBlog.Collection.Version,
            version_id,
            dgettext_noop("errors", "collection"),
            Ash.Scope.to_opts(context)
          )
        end)
      end
    end

    read :master_preview_version do
      description "Preview a specific version without modifying the collection (master users)"
      multitenancy :bypass
      get? true

      argument :collection_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      filter expr(id == ^arg(:collection_id))

      prepare fn query, context ->
        version_id = Ash.Query.get_argument(query, :version_id)

        Ash.Query.after_action(query, fn _query, results ->
          MishkaBlog.Resources.Changes.RestoreVersion.preview(
            results,
            MishkaBlog.Collection.Version,
            version_id,
            dgettext_noop("errors", "collection"),
            Ash.Scope.to_opts(context, tenant: nil)
          )
        end)
      end
    end
  end

  # Authorization policies for collection access
  policies do
    # Allow public access to view active collections
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    # Admin access for all other actions
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

    # Every site's rows at once: a master only. A call made with `authorize?: false` skips this.
    policy action(:read_any) do
      forbid_unless actor_attribute_equals(:site_id, nil)

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:post", "admin:api:blog:post"]}
    end
  end

  # PubSub configuration for real-time updates
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "collection"

    # Tenant actions
    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions (same topics, different actions)
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_restore_version, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # A collection names only records of its own site that are not archived, whoever writes it.
  # Checked when the id changes, so any other update keeps its atomic path.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :parent_collection_id,
              resource: MishkaBlog.Collection,
              label: dgettext_noop("errors", "parent collection"),
              read_action: :read_any},
             where: [changing(:parent_collection_id)]

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :language_group_id,
              resource: MishkaBlog.Collection,
              label: dgettext_noop("errors", "language group"),
              read_action: :read_any},
             where: [changing(:language_group_id)]
  end

  # Multi-tenancy configuration - collections are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Collections are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Name of the collection"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the collection"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      constraints max_length: 2000, trim?: true
      description "Optional description of the collection"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:active, :archived, :draft]
      description "Status of the collection (active, archived, draft)"
    end

    attribute :schema, {:array, :map} do
      default []
      public? true
      description "Schema.org structured data"
    end

    attribute :seo_tags, {:array, :map} do
      default []
      public? true

      constraints items: [
                    fields: [
                      tag: [
                        type: :string,
                        allow_nil?: false
                      ],
                      attrs: [
                        type: :map,
                        allow_nil?: false
                      ],
                      content: [
                        type: :string,
                        allow_nil?: true
                      ]
                    ]
                  ]

      description "SEO meta tags and structured data"
    end

    attribute :permissions, {:array, :string} do
      default []
      public? true
      description "Permission strings required to open this category on its page"
    end

    attribute :featured, :boolean do
      default false
      public? true
      description "Whether the collection is featured"
    end

    attribute :display_order, :integer do
      allow_nil? true
      public? true
      default 0
      constraints min: 0
      description "Sorting position for display ordering"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Primary language of the collection (ISO 639-1 code, e.g., en, fa, ar, ru)"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking all language variants of this collection together"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this collection belongs to"
    end

    belongs_to :parent_collection, MishkaBlog.Collection do
      allow_nil? true
      public? true
      description "Parent collection for nested hierarchies"
    end

    belongs_to :master_parent_collection, MishkaBlog.Collection do
      source_attribute :parent_collection_id
      destination_attribute :id
      allow_nil? true
      public? true
      read_action :read_any
      define_attribute? false
      description "Parent collection for master users (bypasses tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :child_collections, MishkaBlog.Collection do
      public? true
      destination_attribute :parent_collection_id
      description "Child collections nested under this collection"
    end

    has_many :language_variants, MishkaBlog.Collection do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this collection"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_language_variants, MishkaBlog.Collection do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      read_action :read_any

      description "All language variants of this collection (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public with tenant
    many_to_many :posts, MishkaBlog.BlogPost do
      public? true
      description "Blog posts that belong to this collection"
      through MishkaBlog.PostCollection
      source_attribute_on_join_resource :collection_id
      destination_attribute_on_join_resource :post_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_posts, MishkaBlog.BlogPost do
      public? true
      description "All blog tenantposts  that belong to this collection"
      through MishkaBlog.PostCollection
      source_attribute_on_join_resource :collection_id
      destination_attribute_on_join_resource :post_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_posts, MishkaBlog.BlogPost do
      public? true
      description "All blog posts (bypass tenant) that belong to this collection"
      through MishkaBlog.PostCollection
      source_attribute_on_join_resource :collection_id
      destination_attribute_on_join_resource :post_id
      read_action :read_any

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Version management relationship
    # Loaded through `:sorted_versions` as whoever runs the read. A version query handed to a load
    # is left unbuilt (`Ash.Query.new/1`) so that this action builds it for that reader.
    has_many :sorted_versions, MishkaBlog.Collection.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      read_action :sorted_versions
      sort version_inserted_at: :desc
      description "All versions of this collection sorted by insertion date descending"
    end
  end

  calculations do
    # Who may open the category: its own permissions, else its nearest parent's.
    calculate :effective_permissions,
              {:array, :string},
              {MishkaBlog.Resources.Calculations.EffectivePermissions, kind: :collection}

    calculate :version_count, :integer do
      description "Total number of versions for this collection"
      public? true

      calculation fn records, context ->
        collection_ids = Enum.map(records, & &1.id)

        version_counts =
          MishkaBlog.Collection.Version
          |> Ash.Query.filter(version_source_id in ^collection_ids)
          |> Ash.Query.select([:version_source_id])
          |> Ash.read!(Ash.Scope.to_opts(context, action: :read_any))
          |> Enum.frequencies_by(& &1.version_source_id)

        {:ok, Enum.map(records, fn record -> Map.get(version_counts, record.id, 0) end)}
      end
    end

    calculate :latest_version, :struct do
      description "The most recent version of this collection"
      public? true
      constraints instance_of: MishkaBlog.Collection.Version

      calculation fn records, context ->
        collection_ids = Enum.map(records, & &1.id)

        latest_versions =
          MishkaBlog.Collection.Version
          |> Ash.Query.filter(version_source_id in ^collection_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context, action: :read_any))
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {id, versions} -> {id, List.first(versions)} end)

        {:ok, Enum.map(records, fn record -> Map.get(latest_versions, record.id) end)}
      end
    end

    calculate :recent_versions, {:array, :struct} do
      description "The 10 most recent versions of this collection, sorted newest first"
      public? true
      constraints items: [instance_of: MishkaBlog.Collection.Version]

      calculation fn records, context ->
        collection_ids = Enum.map(records, & &1.id)

        recent_versions =
          MishkaBlog.Collection.Version
          |> Ash.Query.filter(version_source_id in ^collection_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context, action: :read_any))
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {id, versions} -> {id, Enum.take(versions, 10)} end)

        {:ok, Enum.map(records, fn record -> Map.get(recent_versions, record.id, []) end)}
      end
    end
  end

  aggregates do
    count :post_count, :tenant_posts do
      public? true
      multitenancy :bypass
      description "Total number of posts in this collection"
    end

    # WHAT A VISITOR WOULD COUNT. `post_count` above counts drafts, scheduled posts and everything
    # else a reader cannot open, so a public category list offered categories that open empty.
    # Archived posts carry `status: :archived` and are out too. Counted through the posts' public
    # read, which every reader may run; a public read of collections counts only the posts its
    # reader may open (`MishkaBlog.Resources.Preparations.OpenToActor`), and a filter cannot count
    # past what the reader is shown.
    count :published_post_count, :tenant_posts do
      public? true
      multitenancy :bypass
      read_action :public_list
      filterable? false
      filter expr(status == :published)
      description "Number of published posts in this collection"
    end
  end

  identities do
    identity :unique_slug_per_site, [:slug, :site_id] do
      description "Ensures collection slugs are unique within each site for clear identification"
      message dgettext_noop("errors", "Collection slug must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_language_per_group, [:language, :language_group_id, :site_id] do
      description "Ensures each language appears only once per language group within a site"

      message dgettext_noop(
                "errors",
                "A collection with this language already exists in this language group."
              )

      all_tenants? true
      nils_distinct? false
    end
  end
end
