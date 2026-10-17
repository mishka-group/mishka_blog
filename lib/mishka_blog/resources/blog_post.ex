# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.BlogPost do
  @moduledoc """
  Manages blog posts in the MishkaBlog plugin with full versioning and translation support.

  This resource represents individual blog posts with rich text content and comprehensive metadata.
  Each post belongs to a specific site and can have multiple language variants through the translation
  system. Posts support various statuses (draft, published, scheduled, archived) with automatic
  publishing based on scheduled timestamps.

  Blog posts feature full version control through PaperTrail integration, tracking all changes
  with snapshot-based history and the ability to restore previous versions. The resource
  implements soft deletion via archival and provides comprehensive SEO and metadata management
  including Schema.org structured data support, reading time calculation, and featured image handling.

  Database-level constraints ensure data integrity with slug validation, proper scheduling constraints,
  and prevention of modifications to archived posts. Multi-tenant isolation ensures posts
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
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # A post row ends in labelled text buttons rather than icon squares, so each action carries the
  # whole button: the shared shape, and then its own colour. `MishkaCmsCoreWeb.UIAdapters.Admin`
  # draws the icon at 15px, which the design sizes down to 13 — hence the `!`, since `size-*` is set
  # by a base utility too and the runtime compiler's bundle order is not reliable.
  @action_class "inline-flex items-center gap-[5px] bg-transparent p-0 text-[11.5px] " <>
                  "font-semibold transition-colors [&>span:not(.lbl)]:size-[13px]!"

  @edit_action_class @action_class <> " text-[#3a5bc4] hover:text-[#2b48a8]"
  @versions_action_class @action_class <> " text-[#7a5bd0] hover:text-[#5a3fb0]"
  @publish_action_class @action_class <> " text-[#177a53] hover:text-[#0f5e3f]"
  @unpublish_action_class @action_class <> " text-[#c0752a] hover:text-[#9c5e1f]"
  @danger_action_class @action_class <> " text-[#c0473d] hover:text-[#a5352c]"

  # The card keeps every action as an inline text button, as the design draws it. A table row has no
  # room for eight of those, so there the same actions ride in a kebab instead — each a full-width
  # menu row, icon then label, left aligned. Which of the two a reader sees is decided per action by
  # `visible`, reading `state.template`: the card's copies hide in the table and the menu's copies
  # hide in the card, so neither view ever shows both.
  @table_template MishkaGervaz.Table.Templates.Table

  @menu_item "flex w-full items-center gap-2.5 rounded-[8px] px-2.5 py-[7px] text-[12px] " <>
               "font-semibold transition-colors [&_.lbl]:flex-1 [&_.lbl]:text-start"

  @menu_versions @menu_item <> " text-[#7a5bd0] hover:bg-[#f4ecfb]"
  @menu_publish @menu_item <> " text-[#177a53] hover:bg-[#eaf7ef]"
  @menu_unpublish @menu_item <> " text-[#c0752a] hover:bg-[#fdf3e7]"
  @menu_danger @menu_item <> " text-[#c0473d] hover:bg-[#fbeceb]"

  # A table row leads with icon-only squares, the shape every runtime table uses. The label still
  # reaches the DOM as `title` and as the `.lbl` span this hides, so the button keeps an accessible
  # name the card spells out in full.
  @square "grid size-[30px] flex-none place-items-center rounded-[8px] border transition-colors " <>
            "[&_.lbl]:hidden [&>span:not(.lbl)]:size-[15px]!"

  @square_action @square <>
                   " border-[#ecebe6] bg-[#faf9f6] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"

  @square_danger @square <> " border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"

  @admin_fields [
    :title,
    :subtitle,
    :slug,
    :content,
    :excerpt,
    :featured_image_url,
    :status,
    :published_at,
    :scheduled_publish_at,
    :schema,
    :seo_tags,
    :permissions,
    :featured,
    :language,
    :language_group_id,
    :site_id
  ]

  @repo Application.compile_env!(:mishka_cms_core, :repo)

  # Database configuration for blog posts storage with indexing
  postgres do
    table "mishka_blog_posts"
    repo @repo

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:status]
      index [:featured]
      index [:published_at]
      index [:scheduled_publish_at]
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

      check_constraint :scheduled_publish_at, "scheduled_publish_future",
        check: "scheduled_publish_at IS NULL OR scheduled_publish_at > timezone('UTC', NOW())",
        message: dgettext_noop("errors", "Scheduled publish time must be in the future.")

      check_constraint :status, "valid_publish_constraints",
        check: """
        (status != 'published' OR published_at IS NOT NULL) AND
        (status != 'scheduled' OR scheduled_publish_at IS NOT NULL)
        """,
        message:
          dgettext_noop(
            "errors",
            "Published posts must have published_at, scheduled posts must have scheduled_publish_at."
          )
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_post_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_post_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived blog post'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_post_updates();"
      end

      statement :prevent_archived_post_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_post_updates_trigger
          BEFORE UPDATE ON mishka_blog_posts
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_post_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_post_updates_trigger ON mishka_blog_posts;"
      end

      statement :auto_publish_scheduled_posts_function do
        up """
        CREATE OR REPLACE FUNCTION auto_publish_scheduled_posts()
        RETURNS void AS $$
        BEGIN
          UPDATE mishka_blog_posts
          SET status = 'published',
              published_at = scheduled_publish_at
          WHERE status = 'scheduled'
            AND scheduled_publish_at <= timezone('UTC', NOW())
            AND archived_at IS NULL;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS auto_publish_scheduled_posts();"
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

  # Version control configuration for full post history tracking
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

    mixin {MishkaBlog.Resources.Mixins.BlogPostPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "blog_post"

    includes [
      :collections,
      :master_collections,
      :tenant_collections,
      :tags,
      :master_tags,
      :tenant_tags,
      :comments,
      :master_comments,
      :tenant_comments,
      :bloggers,
      :master_bloggers,
      :tenant_bloggers,
      comments: [:author, :author_profile],
      master_comments: [:author],
      tenant_comments: [:author, :author_profile],
      bloggers: [:user],
      master_bloggers: [:user],
      tenant_bloggers: [:user]
    ]

    paginated_includes [
      :collections,
      :master_collections,
      :tenant_collections,
      :tags,
      :master_tags,
      :tenant_tags,
      :comments,
      :master_comments,
      :tenant_comments,
      :bloggers,
      :master_bloggers,
      :tenant_bloggers,
      [:comments, :author],
      [:master_comments, :author],
      [:tenant_comments, :author],
      [:bloggers, :user],
      [:master_bloggers, :user],
      [:tenant_bloggers, :user]
    ]
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :posts
        route "/admin/dashboard/blog/posts"
        stream_name :posts
      end

      source do
        # The sibling editions are preloaded rather than loaded by the `on_load` hook, which only
        # runs for the list read: a single-row re-read — selecting a card — would come back without
        # them and the card's language row would vanish.
        preload do
          always [
            :site,
            :version_count,
            :collection_count,
            :tag_count,
            :comment_count,
            :view_count
          ]

          tenant [:language_variants]
          master master_language_variants: :language_variants
        end
      end

      columns do
        # Newest first, as every runtime list is, by the date each post is shown with; the card page's
        # Sort by turns it around.
        default_sort [{:listed_at, :desc}]

        column :featured_image do
          static true
          requires [:featured_image_url, :title]
          label fn -> dgettext("mishka_gervaz", "Image") end

          # A thumbnail is a fixed 44px square, so the column is sized to it. Left to the grid's
          # first-column default it would claim 1.7fr and open a gap the width of the title beside it.
          ui do
            width "70px"
          end

          render fn record ->
            assigns = %{image_url: record.featured_image_url, title: record.title}

            ~H"""
            <img
              :if={@image_url}
              src={@image_url}
              alt={@title}
              class="size-11 rounded-[10px] bg-[#f4f3ef] overflow-hidden object-cover text-transparent"
            />
            <div
              :if={is_nil(@image_url)}
              class="grid size-11 place-items-center rounded-[10px] bg-[#f4f3ef]"
            >
              <.icon name="hero-newspaper" class="size-[18px] text-[#a8a5a0]" />
            </div>
            """
          end
        end

        column :title do
          label fn -> dgettext("mishka_gervaz", "Title") end

          ui do
            width "minmax(180px,1.8fr)"
          end

          render fn value ->
            assigns = %{title: value}

            ~H"""
            <span class="block truncate text-[13.5px] font-semibold text-[#17161a]">{@title}</span>
            """
          end
        end

        column :site_datetime do
          static true
          requires [:site_id, :site, :inserted_at, :status, :published_at, :scheduled_publish_at]
          sortable true
          sort_field [:listed_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end

          ui do
            width "minmax(140px,1.2fr)"
          end

          render fn record, state ->
            site_name =
              if state.master_user?, do: record.site.name, else: state.current_user.site.name

            assigns = %{
              site_name: site_name,
              date: MishkaBlogWeb.Templates.PostCard.date_label(record),
              master_user?: state.master_user?
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

        column :excerpt do
          label fn -> dgettext("mishka_gervaz", "Description") end

          ui do
            width "minmax(160px,1.6fr)"
          end
        end

        column :stats_info do
          static true

          requires [
            :id,
            :status,
            :archived_at,
            :comment_count,
            :collection_count,
            :tag_count,
            :version_count,
            :language,
            :language_group_id,
            :language_variants,
            :master_language_variants,
            :featured
          ]

          label fn -> dgettext("mishka_gervaz", "Stats") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(150px,1.2fr)"
          end

          render fn record ->
            assigns = %{
              record: record,
              comment_count: record.comment_count || 0,
              collection_count: record.collection_count || 0,
              tag_count: record.tag_count || 0,
              version_count: record.version_count || 0,
              language: record.language,
              featured: record.featured,
              editions: MishkaBlogWeb.Templates.EditionChips.editions(record),
              accent: MishkaCmsCore.LanguageAccent.of(record)
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-x-[11px] gap-y-1.5 text-[11.5px] font-semibold text-[#8a877f]">
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Comments")}>
                <.icon name="hero-chat-bubble-left" class="size-[13px] text-[#c3c0b8]" />
                {@comment_count}
              </span>
              <span
                class="inline-flex items-center gap-[5px]"
                title={dgettext("mishka_gervaz", "Collections")}
              >
                <.icon name="hero-folder" class="size-[13px] text-[#c3c0b8]" />
                {@collection_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Tags")}>
                <.icon name="hero-tag" class="size-[13px] text-[#c3c0b8]" />
                {@tag_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={dgettext("mishka_gervaz", "Versions")}>
                <.icon name="hero-clock" class="size-[13px] text-[#c3c0b8]" />
                {@version_count}
              </span>
              <MishkaBlogWeb.Templates.EditionChips.inline
                id={"post-editions-#{@record.id}"}
                record={@record}
                editions={@editions}
                accent={@accent}
              />
              <span
                :if={@language && @editions == []}
                class="rounded-[5px] bg-[#f4f3ee] px-[6px] py-[2px] text-[10px] font-bold uppercase tracking-[0.04em] text-[#6d6a63]"
                title={dgettext("mishka_gervaz", "Language")}
              >
                {@language}
              </span>
              <span :if={@featured} title={dgettext("mishka_gervaz", "Featured")}>
                <.icon name="hero-star-solid" class="size-[13px] text-[#d9a520]" />
              </span>
            </div>
            """
          end
        end

        # The same four chips the card draws (`MishkaBlogWeb.Templates.PostCard`), drawn here by the
        # `:badge` type rather than by hand, so the row keeps one badge shape with every other table.
        column :status do
          sortable true
          sort_field [:status]
          label fn -> dgettext("mishka_gervaz", "Status") end

          ui do
            type :badge
            width "minmax(110px,0.9fr)"

            extra %{
              colors: %{
                "published" => "bg-[#e6f6ee] text-[#177a53]",
                "draft" => "bg-[#fbf1df] text-[#a5691a]",
                "scheduled" => "bg-[#eeedfb] text-[#5b57d6]",
                "archived" => "bg-[#fbe9e7] text-[#b3433a]"
              },
              labels: %{
                "published" => dgettext_noop("mishka_gervaz", "Published"),
                "draft" => dgettext_noop("mishka_gervaz", "Draft"),
                "scheduled" => dgettext_noop("mishka_gervaz", "Scheduled"),
                "archived" => dgettext_noop("mishka_gervaz", "Archived")
              },
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
          end
        end
      end

      filters do
        filter :search, :text, fields: [:title, :slug, :excerpt]

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

        filter :collection_id, :relation do
          virtual true
          resource MishkaBlog.Collection
          mode :search
          display_field :name
          search_field :name
          min_chars 1
          page_size 15

          load fn query, state ->
            case state.master_user? and Map.get(state.filter_values, :site_id) do
              [_ | _] = site_ids -> Ash.Query.filter(query, site_id in ^site_ids)
              _every_site -> query
            end
          end

          apply fn query, value, context ->
            relationship =
              if context.master_user?, do: "master_collections", else: "tenant_collections"

            Ash.Query.filter_input(query, %{
              relationship => %{"id" => %{"in" => List.wrap(value)}}
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Collection") end
            placeholder fn -> dgettext("mishka_gervaz", "Search collections...") end
          end
        end

        filter :status, :select do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Published"), :published},
              {dgettext("mishka_gervaz", "Draft"), :draft},
              {dgettext("mishka_gervaz", "Scheduled"), :scheduled}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :featured, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured") end
          end
        end

        filter :language, :select do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_blog_posts WHERE language IS NOT NULL ORDER BY language"
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
      end

      row_actions do
        # Every action is listed inline; which of them a reader actually sees is decided per action by
        # `visible`. The card shows them all, as the design draws it. A table row has no width for
        # eight labelled buttons — they spill over the Status column — so there all but the leading
        # few hide and reappear inside the kebab below.
        actions_layout do
          inline [
            :edit,
            :versions,
            :publish,
            :unpublish,
            :archive,
            :unarchive,
            :versions_archived,
            :permanent_destroy,
            :table_edit,
            :table_archive,
            :table_unarchive
          ]

          dropdown [:post_actions]
        end

        action :edit do
          type :edit

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("blog-post-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @edit_action_class
          end
        end

        # The design calls this one "Delete"; it archives, and the archived scope is where a post can
        # actually be destroyed. Named for what the reader means, kept honest by the pair below.
        action :archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this post?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this post?")
          end

          visible fn _record, state ->
            state.archive_status == :archived and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @publish_action_class
          end
        end

        action :table_edit do
          type :edit

          visible fn _record, state ->
            state.archive_status == :active and state.template == @table_template
          end

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("blog-post-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @square_action
          end
        end

        action :table_archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this post?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this post?")
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

        action :publish do
          type :update
          action {:master_publish, :publish}

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Publish") end
            icon "hero-arrow-up"
            class @publish_action_class
          end
        end

        action :unpublish do
          type :update
          action {:master_unpublish, :unpublish}

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Unpublish") end
            icon "hero-arrow-down"
            class @unpublish_action_class
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
                    "Are you sure you want to PERMANENTLY delete this post? This action cannot be undone!"
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

        dropdown :post_actions do
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

          action :menu_publish do
            type :update
            action {:master_publish, :publish}

            visible fn _record, state ->
              state.archive_status == :active and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Publish") end
              icon "hero-arrow-up"
              class @menu_publish
            end
          end

          action :menu_unpublish do
            type :update
            action {:master_unpublish, :unpublish}

            visible fn _record, state ->
              state.archive_status == :active and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Unpublish") end
              icon "hero-arrow-down"
              class @menu_unpublish
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
                      "Are you sure you want to PERMANENTLY delete this post? This action cannot be undone!"
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

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected posts?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected posts?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected posts? This cannot be undone."
            ),
          visible: :archived
      end

      realtime do
        prefix "blog_post"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      events do
        bulk_action MishkaCmsCore.LanguageEditions.BulkActionHandler
      end

      hooks do
        # One row per post, not one per translation — see `MishkaCmsCore.LanguageEditions`. This
        # belongs here rather than on the read action because only a hook runs late enough to see
        # whether a search is active, and a search must reach every language. A live update is
        # asked of the same read, and `on_realtime` redraws a translation's master.
        on_load fn query, state ->
          {:cont, MishkaCmsCore.LanguageEditions.scope_to_masters(query, state)}
        end

        on_realtime fn notification, socket ->
          MishkaCmsCore.LanguageEditions.on_realtime(notification, socket)
        end

        # A delete refused because the post's translations are live answers with an alert that
        # offers to archive — or delete for good — those translations at once. See
        # `MishkaCmsCore.LanguageEditions`.
        on_row_action_error [:delete, :permanent_destroy],
                            &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_error [:archive, :permanent_destroy],
                             &MishkaCmsCore.LanguageEditions.on_delete_refused/3

        on_bulk_action_success [:archive, :permanent_destroy],
                               &MishkaCmsCore.LanguageEditions.on_delete_refused/3
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "posts"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No blog posts found"),
                  icon: "hero-newspaper"

      presentation do
        template MishkaBlogWeb.Templates.PostCard
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaBlogWeb.Templates.PostCard
        ]
      end
    end

    form do
      identity do
        name :post_form
      end

      source do
        preload do
          master [:master_collections, :master_tags, :master_bloggers]
          tenant [:tenant_collections, :tenant_tags, :tenant_bloggers]
        end
      end

      fields do
        field :title, :text do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Title") end
            placeholder fn -> dgettext("mishka_gervaz", "Post title") end
          end
        end

        field :slug do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Slug") end
            placeholder fn -> dgettext("mishka_gervaz", "post-slug") end
          end
        end

        field :status do
          options fn ->
            [
              {dgettext("mishka_gervaz", "Draft"), :draft},
              {dgettext("mishka_gervaz", "Published"), :published},
              {dgettext("mishka_gervaz", "Scheduled"), :scheduled}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end

            description fn ->
              dgettext("mishka_gervaz", "Publishing at the scheduled time is on our roadmap.")
            end
          end
        end

        field :language, :combobox do
          options fn ->
            case Ecto.Adapters.SQL.query(
                   @repo,
                   "SELECT DISTINCT language FROM mishka_blog_posts WHERE language IS NOT NULL ORDER BY language"
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

        field :language_group_id, :relation do
          value_field :language_group_id
          display_field fn record -> "#{record.title} (#{record.language})" end
          search_field :title
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

        field :collection_ids, :relation do
          virtual true
          resource MishkaBlog.Collection
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
            cols =
              cond do
                is_list(Map.get(record, :master_collections)) -> record.master_collections
                is_list(Map.get(record, :tenant_collections)) -> record.tenant_collections
                is_list(Map.get(record, :collections)) -> record.collections
                true -> []
              end

            Enum.map(cols, &to_string(&1.id))
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Collections") end
          end
        end

        field :blogger_ids, :relation do
          virtual true
          resource MishkaBlog.Blogger
          search_field :display_name
          mode :search_multi
          depends_on :site_id

          display_field fn blogger ->
            case blogger do
              %{user: %{email: email}} when not is_nil(email) -> to_string(email)
              %{display_name: name} when not is_nil(name) -> name
              _ -> to_string(blogger.id)
            end
          end

          load fn query, state ->
            query = Ash.Query.load(query, :user)

            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            Ash.Query.filter_input(query, %{site_id: site_id})
          end

          derive_value fn record ->
            bloggers =
              cond do
                is_list(Map.get(record, :master_bloggers)) -> record.master_bloggers
                is_list(Map.get(record, :tenant_bloggers)) -> record.tenant_bloggers
                is_list(Map.get(record, :bloggers)) -> record.bloggers
                true -> []
              end

            Enum.map(bloggers, &to_string(&1.id))
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Bloggers / Authors") end
          end
        end

        field :tag_ids, :relation do
          virtual true
          resource MishkaBlog.Tag
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
            tags =
              cond do
                is_list(Map.get(record, :master_tags)) -> record.master_tags
                is_list(Map.get(record, :tenant_tags)) -> record.tenant_tags
                is_list(Map.get(record, :tags)) -> record.tags
                true -> []
              end

            Enum.map(tags, &to_string(&1.id))
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Tags") end
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            rows 8

            # The rich-text editor, with components placed as blocks; their markers are what is
            # stored. `MishkaCmsCoreWeb.UIAdapters.Admin.textarea/1` is what reads this.
            extra %{content_editor: true}
          end
        end

        field :subtitle, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Subtitle") end
            placeholder fn -> dgettext("mishka_gervaz", "One line under the title") end
            rows 2
          end
        end

        field :excerpt, :textarea do
          ui do
            label fn -> dgettext("mishka_gervaz", "Excerpt") end
            rows 3
          end
        end

        # THE COVER PICTURE: dropped here, or chosen from the site's media library, and filed in its
        # `blog` folder. `MishkaCmsCoreWeb.UIAdapters.Admin.text_input/1` is what reads `media`.
        field :featured_image_url, :text do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured Image") end
            placeholder fn -> dgettext("mishka_gervaz", "https://example.com/image.jpg") end
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

        field :featured do
          ui do
            label fn -> dgettext("mishka_gervaz", "Featured") end
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
            placeholder ~s([{"@type": "BlogPosting", "name": "My Post"}])
          end
        end

        # WHO MAY OPEN THE POST ON ITS PAGE: any of the permission names that exist, stored by name.
        # Empty, it is public. `MishkaBlog.Plugins.PageSeo` answers them, and
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
                "Who may open this post: anyone holding one of these. None: everyone."
              )
            end
          end
        end
      end

      groups do
        group :basic_info do
          fields [
            :title,
            :slug,
            :status,
            :language,
            :site_id,
            :language_group_id,
            :featured
          ]

          ui do
            columns 2
            class ""
          end
        end

        group :relationships do
          fields [:collection_ids, :blogger_ids, :tag_ids]

          ui do
            columns 1
            class ""
          end
        end

        group :content do
          fields [:subtitle, :content, :excerpt, :featured_image_url, :share_card]

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

      # For `textarea/1` only — the adapter falls back to Tailwind for everything else. It is what
      # turns the `content` field's `extra %{content_editor: true}` into the editor.
      presentation do
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin
      end

      hooks do
        # While a post is added, its slug follows the title until the author types one.
        on_validate fn params, state ->
          MishkaCmsCore.Runtime.Helpers.follow_slug(params, state, :title)
        end

        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :title, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=500)"

    field :subtitle, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(optional=[string, max_len=300])"

    field :slug, :string,
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :content, :string, derives: "sanitize(html5) validate(string, not_empty)"

    field :excerpt, :string,
      derives: "sanitize(basic_html, trim) validate(optional=[string, max_len=1000])"

    field :featured_image_url, :string,
      derives: "sanitize(trim) validate(optional=[string, max_len=500])"

    field :status, :atom,
      derives: "validate(atom, enum=Atom[draft::published::scheduled::archived])"

    field :published_at, :utc_datetime,
      derives: "validate(optional=[utc_datetime, past_datetime])"

    field :scheduled_publish_at, :utc_datetime,
      derives: "validate(optional=[utc_datetime, future_datetime])"

    field :schema, {:array, :map}, derives: "validate(list)"
    field :seo_tags, {:array, :map}, derives: "validate(list)"

    field :permissions, {:array, :string},
      derives: "sanitize(each=[trim, downcase], reject_empty, uniq) validate(list)"

    field :featured, :boolean, derives: "validate(boolean)"

    field :language, :string,
      derives: "sanitize(trim, downcase) validate(optional=[string, max_len=20, language_code])"

    field :language_group_id, :uuid, derives: "validate(optional=[uuid])"
  end

  # Field-level authorization policies
  field_policies do
    # Admin-only fields. `comment_count` counts every status, so it would tell a visitor how many
    # comments are waiting for moderation or were marked spam; `approved_comment_count` is the public one.
    field_policy [:version_count, :latest_version, :recent_versions, :comment_count] do
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

      # before/reject seam: a plugin can transform the changeset or add_error to block creation.
      change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook

      # Arguments for assigning relationships during creation
      argument :collection_ids, {:array, :uuid} do
        description "List of collection IDs to assign this post to"
      end

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this post"
      end

      argument :blogger_ids, {:array, :uuid} do
        description "List of blogger IDs to assign as authors"
      end

      validate present([:title])
      validate present([:slug])
      validate present([:content])
      validate present([:status])
      validate present([:language])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop(
                    "errors",
                    "Language group not found or does not belong to your site."
                  )}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)
      change MishkaCmsCore.Runtime.Resources.Changes.SetLanguageGroupId
      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Manage relationships if provided
      change manage_relationship(:collection_ids, :tenant_collections,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:blogger_ids, :tenant_bloggers,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change MishkaBlog.Resources.Changes.PublishLifecycle

      # Highlights the code blocks of the sanitized content, before the row is written, and stores
      # what the content says: its reading time and the components it names.
      change MishkaBlog.Resources.Changes.HighlightCode
      change MishkaBlog.Resources.Changes.ContentFacts

      description "Creates blog post for tenant users - requires tenant context, auto-assigns site_id and language_group_id for master posts"
    end

    create :master_create do
      # Arguments for assigning relationships during creation
      argument :collection_ids, {:array, :uuid} do
        description "List of collection IDs to assign this post to"
      end

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this post"
      end

      argument :blogger_ids, {:array, :uuid} do
        description "List of blogger IDs to assign as authors"
      end

      validate present([:title])
      validate present([:slug])
      validate present([:content])
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

      # Manage relationships within the post's own site
      change manage_relationship(:collection_ids, :tenant_collections,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:blogger_ids, :tenant_bloggers,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change MishkaBlog.Resources.Changes.PublishLifecycle

      # Highlights the code blocks of the sanitized content, before the row is written, and stores
      # what the content says: its reading time and the components it names.
      change MishkaBlog.Resources.Changes.HighlightCode
      change MishkaBlog.Resources.Changes.ContentFacts

      description "Creates blog post for master users - bypasses multi-tenancy, requires explicit site_id, auto-assigns language_group_id for master posts"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      # Arguments for managing relationships during update
      argument :collection_ids, {:array, :uuid} do
        description "List of collection IDs to assign this post to (replaces existing)"
      end

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this post (replaces existing)"
      end

      argument :blogger_ids, {:array, :uuid} do
        description "List of blogger IDs to assign as authors (replaces existing)"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :language_group_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop(
                    "errors",
                    "Language group not found or does not belong to your site."
                  )},
               where: [changing(:language_group_id)]

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived blog post. Please unarchive it first."
                )
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Manage relationships if provided
      change manage_relationship(:collection_ids, :tenant_collections,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:blogger_ids, :tenant_bloggers,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change MishkaBlog.Resources.Changes.PublishLifecycle

      # Highlights the code blocks of the sanitized content, before the row is written, and stores
      # what the content says: its reading time and the components it names.
      change MishkaBlog.Resources.Changes.HighlightCode
      change MishkaBlog.Resources.Changes.ContentFacts

      description "Updates blog post for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates blog post for master users - requires nil tenant context, prevents site_id changes"
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass

      # Arguments for managing relationships during update
      argument :collection_ids, {:array, :uuid} do
        description "List of collection IDs to assign this post to (replaces existing)"
      end

      argument :tag_ids, {:array, :uuid} do
        description "List of tag IDs to assign to this post (replaces existing)"
      end

      argument :blogger_ids, {:array, :uuid} do
        description "List of blogger IDs to assign as authors (replaces existing)"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      # Records are related within the post's own site, whoever the caller is.
      change fn changeset, _context ->
        Ash.Changeset.set_tenant(changeset, changeset.data.site_id)
      end

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived blog post. Please unarchive it first."
                )
      end

      change slugify(:slug, into: :slug, ignore: [".", "!", "?"])

      # Manage relationships within the post's own site
      change manage_relationship(:collection_ids, :tenant_collections,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change manage_relationship(:blogger_ids, :tenant_bloggers,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )

      change MishkaBlog.Resources.Changes.PublishLifecycle

      # Highlights the code blocks of the sanitized content, before the row is written, and stores
      # what the content says: its reading time and the components it names.
      change MishkaBlog.Resources.Changes.HighlightCode
      change MishkaBlog.Resources.Changes.ContentFacts
    end

    read :published do
      description "Reads only published blog posts within current tenant context"
      # pre_get_posts / onContentSearch equivalent: a plugin can narrow/sort the query.
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      filter expr(status == :published)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :drafts do
      description "Reads draft blog posts within current tenant context"
      filter expr(status == :draft)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :scheduled do
      description "Reads scheduled blog posts within current tenant context"
      filter expr(status == :scheduled)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :featured do
      description "Reads featured blog posts within current tenant context"
      filter expr(featured == true and status == :published)
      pagination offset?: true, default_limit: 10, max_page_size: 50, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :public_list do
      description "Public endpoint to list all published blog posts (no authentication required)"
      filter expr(status == :published)
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :post}
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :public_get do
      description "Public endpoint to get a single published blog post by ID (no authentication required)"
      get? true
      filter expr(status == :published)
      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :post}
    end

    read :master_read do
      description "Reads all blog posts system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :read_any do
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, required?: false
    end

    # The post in whatever state it is in, archived included, of the site asked for. The rows that
    # point at a post read it through their `post_in_any_state` relationship to tell its site.
    read :any_state do
      description "Reads a post in any state, archived included, of the site asked for"
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single blog post by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :language_variants do
      description "Retrieves all language variants of a blog post for hreflang tag generation"
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

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived blog posts within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived blog post for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived blog post for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived blog posts system-wide, bypassing tenant filtering"
    end

    update :publish do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:status, :published)

      change fn changeset, _context ->
        if is_nil(changeset.data.published_at) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :published_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )
        else
          changeset
        end
      end

      # A post published names its components to its site's stylesheet.
      change MishkaBlog.Resources.Changes.ContentFacts

      description "Publishes a draft or scheduled blog post immediately"
    end

    update :master_publish do
      description "Publishes a draft or scheduled blog post immediately (master users)"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:status, :published)

      change fn changeset, _context ->
        if is_nil(changeset.data.published_at) do
          Ash.Changeset.force_change_attribute(
            changeset,
            :published_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )
        else
          changeset
        end
      end

      # A post published names its components to its site's stylesheet.
      change MishkaBlog.Resources.Changes.ContentFacts
    end

    update :unpublish do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:status, :draft)
      change set_attribute(:published_at, nil)

      description "Reverts a published blog post back to draft status"
    end

    update :master_unpublish do
      description "Reverts a published blog post back to draft status (master users)"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:status, :draft)
      change set_attribute(:published_at, nil)
    end

    update :schedule do
      accept [:scheduled_publish_at]
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate present([:scheduled_publish_at])
      change set_attribute(:status, :scheduled)

      description "Schedules a blog post for future publication"
    end

    update :master_schedule do
      description "Schedules a blog post for future publication (master users)"
      accept [:scheduled_publish_at]
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present([:scheduled_publish_at])

      change set_attribute(:status, :scheduled)
    end

    update :assign_bloggers do
      description "Replaces post's authors/co-authors with the provided list of blogger IDs"
      accept []
      require_atomic? false

      argument :blogger_ids, {:array, :uuid} do
        allow_nil? false
        description "List of blogger IDs to assign as authors/co-authors of this post"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:blogger_ids, :tenant_bloggers,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_blogger do
      description "Adds a single blogger as author/co-author to the post"
      accept []
      require_atomic? false

      argument :blogger_id, :uuid do
        allow_nil? false
        description "Blogger ID to add as author/co-author"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:blogger_id, :tenant_bloggers,
               type: :append,
               on_no_match: :error
             )
    end

    update :remove_blogger do
      description "Removes a single blogger from the post's authors"
      accept []
      require_atomic? false

      argument :blogger_id, :uuid do
        allow_nil? false
        description "Blogger ID to remove from authors"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:blogger_id, :tenant_bloggers, type: :remove)
    end

    update :assign_collections do
      description "Replaces post's collections with the provided list of collection IDs"
      accept []
      require_atomic? false

      argument :collection_ids, {:array, :uuid} do
        allow_nil? false
        description "List of collection IDs to assign this post to"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:collection_ids, :tenant_collections,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_collection do
      description "Adds post to a single collection"
      accept []
      require_atomic? false

      argument :collection_id, :uuid do
        allow_nil? false
        description "Collection ID to add this post to"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:collection_id, :tenant_collections,
               type: :append,
               on_no_match: :error
             )
    end

    update :remove_collection do
      description "Removes post from a single collection"
      accept []
      require_atomic? false

      argument :collection_id, :uuid do
        allow_nil? false
        description "Collection ID to remove this post from"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:collection_id, :tenant_collections,
               type: :remove,
               on_no_match: :ignore,
               on_missing: :ignore
             )
    end

    update :assign_tags do
      description "Replaces post's tags with the provided list of tag IDs"
      accept []
      require_atomic? false

      argument :tag_ids, {:array, :uuid} do
        allow_nil? false
        description "List of tag IDs to assign to this post"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:tag_ids, :tenant_tags,
               type: :append_and_remove,
               on_no_match: :error,
               on_match: :ignore
             )
    end

    update :add_tag do
      description "Adds a single tag to the post"
      accept []
      require_atomic? false

      argument :tag_id, :uuid do
        allow_nil? false
        description "Tag ID to add to this post"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:tag_id, :tenant_tags, type: :append, on_no_match: :error)
    end

    update :remove_tag do
      description "Removes a single tag from the post"
      accept []
      require_atomic? false

      argument :tag_id, :uuid do
        allow_nil? false
        description "Tag ID to remove from this post"
      end

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change manage_relationship(:tag_id, :tenant_tags, type: :remove)
    end

    destroy :destroy do
      description "Soft deletes blog post by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Blog post is already archived.")}
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
      description "Soft deletes blog post by archiving (master users) - requires nil tenant context"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Blog post is already archived.")}
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
      change set_attribute(:status, :draft)

      change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore

      atomic_upgrade_with :archived

      description "Restores archived blog post to draft status (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived blog post to draft status (master users) - requires nil tenant context"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "Blog post is not archived.")
      end

      change set_attribute(:archived_at, nil)
      change set_attribute(:status, :draft)

      change MishkaCmsCore.Runtime.Resources.Changes.PreventOrphanedTranslationRestore

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion

      description "Permanently removes blog post and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes blog post and version history from database (master users) - irreversible and extremely dangerous"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate MishkaCmsCore.Runtime.Resources.Validations.PreventMasterLanguageDeletion
    end

    # VERSION MANAGEMENT - Read Actions
    read :get_with_versions do
      get? true
      description "Gets a single blog post with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        query
        |> Ash.Query.load(
          sorted_versions:
            MishkaBlog.BlogPost.Version
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
      description "Gets a single blog post with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        query
        |> Ash.Query.load(
          sorted_versions:
            MishkaBlog.BlogPost.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      description "Returns blog post with all versions loaded, sorted by date (tenant users)"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      argument :post_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        post_id = Ash.Query.get_argument(query, :post_id)

        case Ash.get(MishkaBlog.BlogPost, post_id, Ash.Scope.to_opts(context)) do
          {:ok, _post} ->
            query
            |> Ash.Query.filter(id == ^post_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaBlog.BlogPost.Version
                |> Ash.Query.new()
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaBlog.BlogPost)
            )
        end
      end
    end

    read :master_list_versions do
      description "Returns blog post with all versions loaded, sorted by date (master users)"
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      multitenancy :bypass

      argument :post_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, context ->
        post_id = Ash.Query.get_argument(query, :post_id)

        case Ash.get(
               MishkaBlog.BlogPost,
               post_id,
               Ash.Scope.to_opts(context, action: :master_get, tenant: nil)
             ) do
          {:ok, _post} ->
            query
            |> Ash.Query.filter(id == ^post_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaBlog.BlogPost.Version
                |> Ash.Query.new()
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaBlog.BlogPost)
            )
        end
      end
    end

    # VERSION MANAGEMENT - Restore Actions
    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the blog post to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived blog post. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.BlogPost.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "blog post")}

      # A version written before code was highlighted comes back highlighted, with what its content
      # says worked out again.
      change MishkaBlog.Resources.Changes.HighlightCode
      change MishkaBlog.Resources.Changes.ContentFacts
    end

    action :restore_version_api, :struct do
      description "Restores blog post content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaBlog.BlogPost

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        post_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(MishkaBlog.BlogPost, post_id, Ash.Scope.to_opts(context, action: :read))
        |> case do
          {:ok, post} when not is_nil(post) ->
            if !is_nil(post.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived blog post. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = post.site_id

              post
              |> Ash.Changeset.for_update(
                :restore_version,
                %{version_id: version_id},
                Ash.Scope.to_opts(context, tenant: tenant)
              )
              |> Ash.update()
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.BlogPost)}
        end
      end
    end

    update :master_restore_version do
      description "Restores blog post content from a specific version in history (master users)"
      accept []
      require_atomic? false
      multitenancy :bypass

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived blog post. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.BlogPost.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "blog post")}

      # A version written before code was highlighted comes back highlighted, with what its content
      # says worked out again.
      change MishkaBlog.Resources.Changes.HighlightCode
      change MishkaBlog.Resources.Changes.ContentFacts
    end

    action :master_restore_version_api, :struct do
      description "Restores blog post content from a specific version in history (master users - API)"
      constraints instance_of: MishkaBlog.BlogPost

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        post_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(
          MishkaBlog.BlogPost,
          post_id,
          Ash.Scope.to_opts(context, action: :master_get, tenant: nil)
        )
        |> case do
          {:ok, post} when not is_nil(post) ->
            if !is_nil(post.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived blog post. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              post
              |> Ash.Changeset.for_update(
                :master_restore_version,
                %{version_id: version_id},
                Ash.Scope.to_opts(context, tenant: nil)
              )
              |> Ash.update()
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.BlogPost)}
        end
      end
    end

    # VERSION MANAGEMENT - Preview Actions
    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaBlog.BlogPost

      argument :post_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :post_id,
           version: MishkaBlog.BlogPost.Version,
           fields: List.delete(@admin_fields, :site_id),
           label: dgettext_noop("errors", "blog post")}
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaBlog.BlogPost

      argument :post_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :post_id,
           version: MishkaBlog.BlogPost.Version,
           fields: List.delete(@admin_fields, :site_id),
           master: true,
           label: dgettext_noop("errors", "blog post")}
    end
  end

  # Authorization policies for blog post access
  policies do
    # Allow public access to view published posts
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    # The post a comment is on, loaded beside the comment for whoever moderates it.
    bypass accessing_from(MishkaBlog.Comment, :post) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:comment", "admin:api:blog:comment"]}
    end

    bypass accessing_from(MishkaBlog.Comment, :master_post) do
      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:comment", "admin:api:blog:comment"]}
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
    prefix "blog_post"

    # Tenant actions
    publish :create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :publish, [[nil, :site_id], "updated"]
    publish :unpublish, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_restore_version, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_publish, [[nil, :site_id], "updated"]
    publish :master_unpublish, [[nil, :site_id], "updated"]
    publish :master_schedule, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # A post names only records of its own site that are not archived, whoever writes it. Checked
  # when the id changes, so any other update keeps its atomic path.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :language_group_id,
              resource: MishkaBlog.BlogPost,
              label: dgettext_noop("errors", "language group"),
              read_action: :read_any},
             where: [changing(:language_group_id)]

    # A create's before-action hooks, a plugin's among them, run after the check above, so what
    # they write is checked again just before the insert.
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :language_group_id,
              resource: MishkaBlog.BlogPost,
              label: dgettext_noop("errors", "language group"),
              read_action: :read_any},
             on: [:create],
             before_action?: true
  end

  # Multi-tenancy configuration - blog posts are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Blog posts are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500, trim?: true
      description "Title of the blog post"
    end

    attribute :subtitle, :string do
      allow_nil? true
      public? true
      constraints max_length: 300, trim?: true
      description "A line under the title saying what the post is about"
    end

    attribute :slug, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "URL-friendly slug for the blog post"
    end

    attribute :content, :string do
      allow_nil? false
      public? true
      description "Rich text content of the blog post"
    end

    # WORKED OUT WITH THE CONTENT, never written by hand nor on a read —
    # `MishkaBlog.Resources.Changes.ContentFacts`.
    attribute :content_components, {:array, :string} do
      allow_nil? true
      public? false
      description "The components the content's markers name, nil when it names none"
    end

    # WORKED OUT WITH THE CONTENT, never written by hand nor on a read —
    # `MishkaBlog.Resources.Changes.ContentFacts`.
    attribute :content_icons, {:array, :string} do
      allow_nil? true
      public? false
      description "The icon classes the content names, nil when it names none"
    end

    # WORKED OUT WITH THE CONTENT, never written by hand nor on a read —
    # `MishkaBlog.Resources.Changes.ContentFacts`.
    attribute :content_classes, {:array, :string} do
      allow_nil? true
      public? false
      description "The classes the content writes, nil when it writes none"
    end

    attribute :reading_time_minutes, :integer do
      allow_nil? true
      public? true

      description "Estimated reading time in minutes: the content's words at 200 a minute, at least 1"
    end

    attribute :excerpt, :string do
      allow_nil? true
      public? true
      constraints max_length: 1000, trim?: true
      description "Summary text for the blog post"
    end

    attribute :featured_image_url, :string do
      allow_nil? true
      public? true
      constraints max_length: 500, trim?: true
      description "URL of the main image for the blog post"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :draft
      constraints one_of: [:draft, :published, :scheduled, :archived]
      description "Status of the blog post (draft, published, scheduled, archived)"
    end

    attribute :published_at, :utc_datetime do
      allow_nil? true
      public? true
      description "Timestamp when the post was published"
    end

    attribute :scheduled_publish_at, :utc_datetime do
      allow_nil? true
      public? true
      description "Future timestamp for scheduled publication"
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
      description "Permission strings required to open this post on its page"
    end

    attribute :featured, :boolean do
      default false
      public? true
      description "Whether the blog post is featured"
    end

    attribute :language, :string do
      allow_nil? false
      public? true
      default "en"
      constraints trim?: true, max_length: 10
      description "Primary language of the blog post (ISO 639-1 code, e.g., en, fa, ar, ru)"
    end

    attribute :language_group_id, :uuid do
      allow_nil? true
      public? true
      description "Shared ID linking all language variants of this blog post together"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this blog post belongs to"
    end

    has_many :language_variants, MishkaBlog.BlogPost do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      description "All language variants (translations) of this blog post"
    end

    # Bypass relationship - for master admin users without tenant
    has_many :master_language_variants, MishkaBlog.BlogPost do
      public? true
      destination_attribute :language_group_id
      source_attribute :language_group_id
      read_action :read_any

      description "All language variants of this blog post (master admin access, bypass tenant)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public/guest users
    many_to_many :bloggers, MishkaBlog.Blogger do
      public? true
      description "Bloggers who authored or co-authored this post (public access)"
      through MishkaBlog.PostBlogger
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :blogger_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_bloggers, MishkaBlog.Blogger do
      public? true
      description "Bloggers who authored or co-authored this post (tenant admin access)"
      through MishkaBlog.PostBlogger
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :blogger_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_bloggers, MishkaBlog.Blogger do
      public? true

      description "Bloggers who authored or co-authored this post (master admin access, bypass tenant)"

      through MishkaBlog.PostBlogger
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :blogger_id
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public/guest users
    many_to_many :collections, MishkaBlog.Collection do
      public? true
      description "Collections this post belongs to (public access)"
      through MishkaBlog.PostCollection
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :collection_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_collections, MishkaBlog.Collection do
      public? true
      description "Collections this post belongs to (tenant admin access)"
      through MishkaBlog.PostCollection
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :collection_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_collections, MishkaBlog.Collection do
      public? true
      description "Collections this post belongs to (master admin access, bypass tenant)"
      through MishkaBlog.PostCollection
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :collection_id
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public/guest users
    many_to_many :tags, MishkaBlog.Tag do
      public? true
      description "Tags categorizing this post (public access)"
      through MishkaBlog.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    many_to_many :tenant_tags, MishkaBlog.Tag do
      public? true
      description "Tags categorizing this post (tenant admin access)"
      through MishkaBlog.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
    end

    # Bypass relationship - for admin users without tenant
    many_to_many :master_tags, MishkaBlog.Tag do
      public? true
      description "Tags categorizing this post (master admin access, bypass tenant)"
      through MishkaBlog.PostTag
      source_attribute_on_join_resource :post_id
      destination_attribute_on_join_resource :tag_id
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    # Relationship - for public/guest users
    has_many :comments, MishkaBlog.Comment do
      public? true
      destination_attribute :post_id
      description "Comments on this blog post (public access, approved only)"
      read_action :public_list
    end

    # Relationship - for admin users with tenant
    has_many :tenant_comments, MishkaBlog.Comment do
      public? true
      destination_attribute :post_id
      description "Comments on this blog post (tenant admin access, all statuses)"
    end

    # Bypass relationship - for admin users without tenant
    has_many :master_comments, MishkaBlog.Comment do
      public? true
      destination_attribute :post_id
      description "Comments on this blog post (master admin access, bypass tenant)"
      read_action :master_read

      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    has_many :bookmarks, MishkaBlog.PostBookmark do
      public? true
      destination_attribute :post_id
      description "User bookmarks for this blog post"
    end

    has_many :ratings, MishkaBlog.PostRating do
      public? true
      destination_attribute :post_id
      description "User ratings for this blog post (for schema.org structured data)"
    end

    has_many :views, MishkaBlog.PostView do
      public? true
      destination_attribute :post_id
      description "Page views for this blog post"
    end

    # VERSION MANAGEMENT - sorted_versions relationship for loading version history
    # Loaded through `:sorted_versions` as whoever runs the read. A version query handed to a load
    # is left unbuilt (`Ash.Query.new/1`) so that this action builds it for that reader.
    has_many :sorted_versions, MishkaBlog.BlogPost.Version do
      public? true
      destination_attribute :version_source_id
      read_action :sorted_versions
      description "Version history for this blog post, sorted by creation date"
    end
  end

  calculations do
    # THE DATE A POST IS LISTED BY — the one its card and its row show
    # (`MishkaBlogWeb.Templates.PostCard.date_label/1`): a scheduled post's due date, else when it was
    # published, else when it was written. The admin list sorts by it, so the order is the order of the
    # dates the reader sees.
    calculate :listed_at,
              :utc_datetime_usec,
              expr(
                if status == :scheduled and not is_nil(scheduled_publish_at) do
                  scheduled_publish_at
                else
                  if is_nil(published_at), do: inserted_at, else: published_at
                end
              )

    # the_content / onContentPrepare equivalent: load :rendered_content to display plugin-transformed body.
    calculate :rendered_content,
              :string,
              {MishkaCmsCore.Runtime.Resources.Calculations.RenderContent, source: :content}

    # Who may open the post: its own permissions, else its categories'.
    calculate :effective_permissions,
              {:array, :string},
              {MishkaBlog.Resources.Calculations.EffectivePermissions, kind: :post}

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaBlog.BlogPost.Version
      description "Returns the most recent version for the blog post"

      calculation fn records, context ->
        post_ids = Enum.map(records, & &1.id)

        latest_versions =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^post_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        Enum.map(records, fn post ->
          Map.get(latest_versions, post.id)
        end)
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaBlog.BlogPost.Version]
      description "Returns up to 10 most recent versions"

      calculation fn records, context ->
        post_ids = Enum.map(records, & &1.id)

        recent_versions =
          MishkaBlog.BlogPost.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^post_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)

        Enum.map(records, fn post ->
          Map.get(recent_versions, post.id, [])
          |> Enum.take(10)
        end)
      end
    end
  end

  aggregates do
    count :collection_count, :tenant_collections do
      public? true
      multitenancy :bypass
      description "Total number of collections this post belongs to"
    end

    count :tag_count, :tenant_tags do
      public? true
      multitenancy :bypass
      description "Total number of tags assigned to this post"
    end

    count :blogger_count, :tenant_bloggers do
      public? true
      multitenancy :bypass
      description "Total number of bloggers/authors for this post"
    end

    count :view_count, :views do
      public? true
    end

    avg :rating_average, :ratings, :rating do
      public? true
    end

    count :rating_count, :ratings do
      public? true
    end

    count :bookmark_count, :bookmarks do
      public? true
    end

    # Counted whoever may read the comments themselves: it is an admin-only field of the post, read
    # by a holder of the post area (see `field_policies`).
    count :comment_count, :tenant_comments do
      public? true
      multitenancy :bypass
      authorize? false
      description "Every comment on the post, in every status — for moderators"
    end

    # Counted through `:comments`, so through `Comment.public_list` — the approved comments, the ones
    # a visitor can read.
    count :approved_comment_count, :comments do
      public? true
      multitenancy :bypass
      description "The approved comments a visitor can read"
    end

    count :version_count, :sorted_versions do
      public? true
      multitenancy :bypass
    end
  end

  identities do
    identity :unique_slug_per_site, [:slug, :site_id] do
      description "Ensures blog post slugs are unique within each site for clear identification"
      message dgettext_noop("errors", "Blog post slug must be unique within a site.")
      all_tenants? true
      nils_distinct? false
    end

    identity :unique_language_per_group, [:language, :language_group_id, :site_id] do
      description "Ensures each language appears only once per language group within a site"

      message dgettext_noop(
                "errors",
                "A blog post with this language already exists in this language group."
              )

      all_tenants? true
      nils_distinct? false
    end
  end
end
