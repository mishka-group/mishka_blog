defmodule MishkaBlog.Comment do
  @moduledoc """
  Manages blog post comments in the MishkaBlog plugin with full versioning support.

  This resource represents comments on blog posts with support for nested threading
  through parent-child relationships. Each comment belongs to a specific site (via site_id)
  and a blog post, and can have replies, creating conversation threads. Comments
  support multiple statuses for moderation workflows (pending, approved, flagged, spam).

  Comments feature full version control through PaperTrail integration, tracking
  all changes with snapshot-based history including content edits, status changes,
  and moderation actions. The resource implements soft deletion via archival and
  provides comprehensive metadata tracking including sender information (IP address,
  user agent) for moderation and security purposes.

  Comments can be pinned to highlight important discussions, and the threading system
  enables rich conversation structures. This resource uses multi-tenancy with site_id
  as the tenant attribute, ensuring comments are scoped to their respective sites.

  ## Multi-Tenancy

  Comments are site-specific and use attribute-based multi-tenancy:
  - Tenant actions require a site_id context
  - Master actions (master_read, master_permanent_destroy) can bypass tenant filtering
  - Public actions (public_list, public_get) show only approved comments

  ## Public Access

  - `public_list` - Lists all approved comments (paginated)
  - `public_get` - Gets a single approved comment by ID
  - `approved_by_post` - Lists approved comments for a specific post
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    authorizers: [Ash.Policy.Authorizer],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaCmsCore.CoreComponents, only: [icon: 1]
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # A comment card ends in labelled text buttons rather than icon squares, so each action carries the
  # whole button: the shared shape, then its own colour. `MishkaCmsCoreWeb.UIAdapters.Admin` draws
  # the icon at 15px, which the design sizes down to 13 — hence the `!`, since `size-*` is set by a
  # base utility too and the runtime compiler's bundle order is not reliable.
  @action_class "inline-flex items-center gap-[5px] bg-transparent p-0 text-[11.5px] " <>
                  "font-semibold transition-colors [&>span:not(.lbl)]:size-[13px]!"

  @edit_action_class @action_class <> " text-[#3a5bc4] hover:text-[#2b48a8]"
  # Reply is the design's odd one out — dark, not coloured like the moderation verbs beside it.
  @reply_action_class @action_class <> " text-[#5c5a54] hover:text-[#4f4bcc]"
  @approve_action_class @action_class <> " text-[#177a53] hover:text-[#0f5e3f]"
  @flag_action_class @action_class <> " text-[#c0752a] hover:text-[#9c5e1f]"
  @pin_action_class @action_class <> " text-[#b59321] hover:text-[#8f741a]"
  @danger_action_class @action_class <> " text-[#c0473d] hover:text-[#a5352c]"

  # Nine labelled buttons will not fit a table row — they ran over the Post and Status cells beside
  # them. There the three verbs a moderator reaches for become icon squares and the other six fold
  # into a kebab. Which copy a reader sees is decided per action by `visible`, reading `state.template`.
  @table_template MishkaGervaz.Table.Templates.Table

  @square "grid size-[30px] flex-none place-items-center rounded-[8px] border transition-colors " <>
            "[&_.lbl]:hidden [&>span:not(.lbl)]:size-[15px]!"

  @square_action @square <>
                   " border-[#ecebe6] bg-[#faf9f6] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"

  @square_approve @square <> " border-[#cfe8db] bg-[#f1f9f4] text-[#177a53] hover:bg-[#e6f6ee]"
  @square_danger @square <> " border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"

  # The overflow actions ride in the kebab, each a full-width menu row: icon then label, left aligned.
  @menu_item "flex w-full items-center gap-2.5 rounded-[8px] px-2.5 py-[7px] text-[12px] " <>
               "font-semibold transition-colors [&_.lbl]:flex-1 [&_.lbl]:text-start"

  @menu_neutral @menu_item <> " text-[#5c5a54] hover:bg-[#f2f1ec]"
  @menu_flag @menu_item <> " text-[#c0752a] hover:bg-[#fdf1e5]"
  @menu_pin @menu_item <> " text-[#b59321] hover:bg-[#fbf4dd]"
  @menu_danger @menu_item <> " text-[#c0473d] hover:bg-[#fbeceb]"

  @admin_fields [
    :post_id,
    :parent_comment_id,
    :author_id,
    :content,
    :status,
    :sender_data,
    :is_pinned,
    :site_id
  ]

  # Database configuration for comments storage with indexing
  postgres do
    table "mishka_blog_comments"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:post_id]
      index [:parent_comment_id]
      index [:author_id]
      index [:status]
      index [:is_pinned]
      index [:inserted_at]
    end

    check_constraints do
      check_constraint :content, "content_not_empty",
        check: "length(trim(content)) > 0",
        message: dgettext_noop("errors", "Comment content cannot be empty.")
    end

    references do
      reference :post, on_delete: :delete
      reference :site, on_delete: :delete
      reference :author, on_delete: :nilify
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_comment_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_comment_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived comment'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_comment_updates();"
      end

      statement :prevent_archived_comment_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_comment_updates_trigger
          BEFORE UPDATE ON mishka_blog_comments
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_comment_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_comment_updates_trigger ON mishka_blog_comments;"
      end
    end
  end

  # Soft deletion configuration using archived_at timestamp
  archive do
    exclude_read_actions [
      :any_state,
      :archived,
      :get_archived,
      :master_get,
      :master_get_archived,
      :master_archived
    ]

    exclude_destroy_actions [:permanent_destroy, :master_permanent_destroy]
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "comment"

    includes [:author, :author_profile, :parent_comment, :replies]

    paginated_includes [:replies]
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :comments
        route "/admin/dashboard/blog/comments"
        stream_name :comments
      end

      source do
        preload do
          always [
            :site,
            :author,
            :author_profile,
            :author_master?,
            :upvote_count,
            :downvote_count
          ]

          tenant [:post]
          master master_post: :post
        end
      end

      columns do
        # WHEN A COMMENT CAME, sorted by but drawn inside the author's line: newest first, and the card
        # page's Sort by turns it around.
        column :inserted_at do
          visible false
          sortable true
          label fn -> dgettext("mishka_gervaz", "Date") end
        end

        # The author's initial tile and name, at the row's scale — the same pair the card leads
        # with; see `MishkaBlogWeb.Templates.CommentCard.author/1` for who the name is.
        column :author_info do
          static true
          requires [:id, :author, :author_id, :author_profile, :author_master?, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Author") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(170px,1.3fr)"
          end

          render fn record ->
            author = MishkaBlogWeb.Templates.CommentCard.author(record)

            assigns = %{
              id: record.id,
              author: author,
              initial: author |> String.first() |> String.upcase(),
              date:
                MishkaBlogWeb.Live.Admin.Dashboard.Home.Index.strftime(
                  record.inserted_at,
                  "%b %d, %Y"
                )
            }

            ~H"""
            <div class="flex min-w-0 items-center gap-2.5">
              <div class="grid size-8 flex-none place-items-center rounded-full bg-[#eef1fc]">
                <span id={"comment-author-initial-#{@id}"} class="text-[12px] font-bold text-[#4f4bcc]">
                  {@initial}
                </span>
              </div>
              <div class="min-w-0">
                <div
                  id={"comment-author-#{@id}"}
                  class="truncate text-[12.5px] font-semibold text-[#17161a]"
                  title={@author}
                >
                  {@author}
                </div>
                <div class="text-[11px] font-medium text-[#a8a5a0]">{@date}</div>
              </div>
            </div>
            """
          end
        end

        # The row's widest cell by design: everything else on it is a chip or a name, and the comment
        # is the only thing a moderator actually reads.
        column :content do
          static true
          requires [:content]
          label fn -> dgettext("mishka_gervaz", "Content") end

          ui do
            width "minmax(200px,2.2fr)"
          end

          render fn record ->
            assigns = %{content: record.content}

            ~H"""
            <p class="line-clamp-2 text-[12.5px] leading-[1.5] text-[#3a382f]" title={@content}>
              {@content}
            </p>
            """
          end
        end

        column :post_title do
          static true
          requires [:post]
          label fn -> dgettext("mishka_gervaz", "Post") end

          ui do
            width "minmax(150px,1.4fr)"
          end

          render fn record ->
            assigns = %{title: if(record.post, do: record.post.title, else: nil)}

            ~H"""
            <div :if={@title} class="flex min-w-0 items-center gap-[6px]" title={@title}>
              <.icon name="hero-document-text" class="size-[13px] shrink-0 text-[#c3c0b8]" />
              <span class="truncate text-[12.5px] font-medium text-[#3a382f]">{@title}</span>
            </div>
            <span :if={is_nil(@title)} class="text-[12px] font-medium text-[#a8a5a0]">{gettext("—")}</span>
            """
          end
        end

        # The same four chips the card draws (`MishkaBlogWeb.Templates.CommentCard`), in the `:badge`
        # type's shape rather than hand-written, so the row matches every other table.
        column :status do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Status") end

          ui do
            type :badge
            width "minmax(105px,0.85fr)"

            extra %{
              colors: %{
                "approved" => "bg-[#e6f6ee] text-[#177a53]",
                "pending" => "bg-[#fbf1df] text-[#a5691a]",
                "flagged" => "bg-[#fdefe3] text-[#b8611c]",
                "spam" => "bg-[#fbe9e7] text-[#b3433a]"
              },
              labels: %{
                "approved" => dgettext_noop("mishka_gervaz", "Approved"),
                "pending" => dgettext_noop("mishka_gervaz", "Pending"),
                "flagged" => dgettext_noop("mishka_gervaz", "Flagged"),
                "spam" => dgettext_noop("mishka_gervaz", "Spam")
              },
              default_color: "bg-[#f2f1ec] text-[#8a877f]"
            }
          end
        end

        # Pinned state and the vote tallies read as one group of markers, so they share a cell rather
        # than each holding a track of their own the way `is_pinned` used to.
        column :stats_info do
          static true
          requires [:is_pinned, :upvote_count, :downvote_count]
          label fn -> dgettext("mishka_gervaz", "Stats") end
          visible fn state -> state.template.name() == :table end

          ui do
            width "minmax(120px,1fr)"
          end

          render fn record ->
            assigns = %{
              is_pinned: record.is_pinned,
              upvote_count: record.upvote_count || 0,
              downvote_count: record.downvote_count || 0
            }

            ~H"""
            <div class="flex flex-wrap items-center gap-x-[11px] gap-y-1.5 text-[11.5px] font-semibold text-[#8a877f]">
              <span class="inline-flex items-center gap-[5px]" title={gettext("Upvotes")}>
                <.icon name="hero-hand-thumb-up" class="size-[13px] text-[#c3c0b8]" />
                {@upvote_count}
              </span>
              <span class="inline-flex items-center gap-[5px]" title={gettext("Downvotes")}>
                <.icon name="hero-hand-thumb-down" class="size-[13px] text-[#c3c0b8]" />
                {@downvote_count}
              </span>
              <span :if={@is_pinned} title={gettext("Pinned")}>
                <.icon name="hero-bookmark-solid" class="size-[13px] text-[#4f4bcc]" />
              </span>
            </div>
            """
          end
        end
      end

      filters do
        # TODO: we need to change it with search LIKE by author email
        filter :search, :text do
          fields [:content]

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
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Flagged"), :flagged},
              {dgettext("mishka_gervaz", "Spam"), :spam}
            ]
          end

          ui do
            prompt dgettext_noop("mishka_gervaz", "All Statuses")
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        filter :post_id, :relation do
          mode :search
          display_field :title
          search_field :title
          min_chars 1
          page_size 15

          load fn query, state ->
            case state.master_user? and Map.get(state.filter_values, :site_id) do
              [_ | _] = site_ids -> Ash.Query.filter(query, site_id in ^site_ids)
              _every_site -> query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Post") end
            placeholder fn -> dgettext("mishka_gervaz", "Search posts...") end
          end
        end

        filter :is_pinned, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Pinned") end
          end
        end
      end

      row_actions do
        # Every action not living in the kebab has to be named here, card copy and table copy alike;
        # `visible` is what picks between them at render time.
        actions_layout do
          inline [
            :edit,
            :reply,
            :approve,
            :flag,
            :mark_spam,
            :pin,
            :unpin,
            :archive,
            :unarchive,
            :permanent_destroy,
            :table_edit,
            :table_approve,
            :table_archive,
            :table_unarchive
          ]

          dropdown [:comment_actions]
        end

        action :table_edit do
          type :edit
          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("comment-form-modal") end

          visible fn _record, state ->
            state.archive_status == :active and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @square_action
          end
        end

        action :table_approve do
          type :update
          action {:master_approve, :approve}

          visible fn _record, state ->
            state.archive_status == :active and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Approve") end
            icon "hero-check-circle"
            class @square_approve
          end
        end

        action :table_archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this comment?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this comment?")
          end

          visible fn _record, state ->
            state.archive_status == :archived and state.template == @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @square_approve
          end
        end

        dropdown :comment_actions do
          ui do
            label fn -> dgettext("mishka_gervaz", "Actions") end
            icon "hero-ellipsis-vertical"
          end

          action :menu_reply do
            type :event
            event "reply"

            visible fn _record, state ->
              state.archive_status == :active and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Reply") end
              icon "reply"
              class @menu_neutral
            end
          end

          action :menu_pin do
            type :update
            action {:master_pin, :pin}

            visible fn record, state ->
              is_nil(record.archived_at) and !record.is_pinned and
                state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Pin") end
              icon "hero-bookmark"
              class @menu_pin
            end
          end

          action :menu_unpin do
            type :update
            action {:master_unpin, :unpin}

            visible fn record, state ->
              is_nil(record.archived_at) and record.is_pinned and
                state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Unpin") end
              icon "hero-bookmark-slash"
              class @menu_pin
            end
          end

          separator label: dgettext_noop("mishka_gervaz", "Moderation")

          action :menu_flag do
            type :update
            action {:master_flag, :flag}

            visible fn _record, state ->
              state.archive_status == :active and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Flag") end
              icon "hero-flag"
              class @menu_flag
            end
          end

          action :menu_mark_spam do
            type :update
            action {:master_mark_spam, :mark_spam}

            visible fn _record, state ->
              state.archive_status == :active and state.template == @table_template
            end

            ui do
              label fn -> dgettext("mishka_gervaz", "Spam") end
              icon "hero-exclamation-circle"
              class @menu_danger
            end
          end

          separator label: dgettext_noop("mishka_gervaz", "Permanent")

          action :menu_permanent_destroy do
            type :permanent_destroy

            confirm dgettext_noop(
                      "mishka_gervaz",
                      "Are you sure you want to PERMANENTLY delete this comment? This action cannot be undone!"
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

          js fn _record -> MishkaCmsCore.CoreComponents.show_modal("comment-form-modal") end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil"
            class @edit_action_class
          end
        end

        action :reply do
          type :event
          event "reply"

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Reply") end
            icon "reply"
            class @reply_action_class
          end
        end

        action :approve do
          type :update
          action {:master_approve, :approve}

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Approve") end
            icon "hero-check-circle"
            class @approve_action_class
          end
        end

        action :flag do
          type :update
          action {:master_flag, :flag}

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Flag") end
            icon "hero-flag"
            class @flag_action_class
          end
        end

        action :mark_spam do
          type :update
          action {:master_mark_spam, :mark_spam}

          visible fn _record, state ->
            state.archive_status == :active and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Spam") end
            icon "hero-exclamation-circle"
            class @danger_action_class
          end
        end

        action :pin do
          type :update
          action {:master_pin, :pin}

          visible fn record, state ->
            is_nil(record.archived_at) and !record.is_pinned and
              state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Pin") end
            icon "hero-bookmark"
            class @pin_action_class
          end
        end

        action :unpin do
          type :update
          action {:master_unpin, :unpin}

          visible fn record, state ->
            is_nil(record.archived_at) and record.is_pinned and
              state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Unpin") end
            icon "hero-bookmark-slash"
            class @pin_action_class
          end
        end

        action :archive do
          type :destroy

          confirm fn _record ->
            dgettext("mishka_gervaz", "Are you sure you want to archive this comment?")
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
            dgettext("mishka_gervaz", "Are you sure you want to restore this comment?")
          end

          visible fn _record, state ->
            state.archive_status == :archived and state.template != @table_template
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @approve_action_class
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Are you sure you want to PERMANENTLY delete this comment? This action cannot be undone!"
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
          confirm: dgettext_noop("mishka_gervaz", "Archive selected comments?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected comments?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected comments? This cannot be undone."
            ),
          visible: :archived
      end

      realtime do
        prefix "comment"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "comments"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No comments found"),
                  icon: "hero-chat-bubble-left-right"

      presentation do
        template MishkaBlogWeb.Templates.CommentCard
        ui_adapter MishkaCmsCoreWeb.UIAdapters.Admin

        switchable_templates [
          MishkaGervaz.Table.Templates.Table,
          MishkaBlogWeb.Templates.CommentCard
        ]
      end
    end

    form do
      identity do
        name :comment_form
      end

      fields do
        field :site_id, :relation do
          restricted true
          required true
          show_on :create
          readonly fn state -> Map.has_key?(state.defaults || %{}, :site_id) end
          display_field :name
          search_field :name
          mode :search

          ui do
            label fn -> dgettext("mishka_gervaz", "Site") end
          end
        end

        field :post_id, :relation do
          required true
          show_on :create
          readonly fn state -> Map.has_key?(state.defaults || %{}, :post_id) end
          display_field :title
          search_field :title
          mode :search
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

          ui do
            label fn -> dgettext("mishka_gervaz", "Post") end
          end
        end

        field :author_id, :relation do
          restricted true
          show_on :create
          display_field :email
          search_field :email
          mode :search
          depends_on :site_id

          load fn query, state ->
            site_id =
              if state.master_user? do
                Map.get(state.field_values, :site_id)
              else
                Map.get(state.current_user, :site_id)
              end

            if site_id do
              Ash.Query.filter(query, site_id == ^site_id or is_nil(site_id))
            else
              query
            end
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Author") end
          end
        end

        field :content, :textarea do
          required true

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            rows 5
          end
        end

        field :status, :select do
          required true

          options fn ->
            [
              {dgettext("mishka_gervaz", "Pending"), :pending},
              {dgettext("mishka_gervaz", "Approved"), :approved},
              {dgettext("mishka_gervaz", "Flagged"), :flagged},
              {dgettext("mishka_gervaz", "Spam"), :spam}
            ]
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Status") end
          end
        end

        field :is_pinned, :toggle do
          ui do
            label fn -> dgettext("mishka_gervaz", "Pinned") end
          end
        end

        field :parent_comment_id, :relation do
          readonly fn state ->
            state.mode == :create and Map.has_key?(state.defaults || %{}, :parent_comment_id)
          end

          display_field :content
          search_field :content
          mode :search
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

          ui do
            label fn -> dgettext("mishka_gervaz", "Parent Comment") end
          end
        end
      end

      groups do
        group :basic_info do
          fields [:site_id, :post_id, :author_id, :status, :is_pinned]

          ui do
            label fn -> dgettext("mishka_gervaz", "Basic Information") end
            columns 2
          end
        end

        group :content do
          fields [:content]

          ui do
            label fn -> dgettext("mishka_gervaz", "Content") end
            columns 1
          end
        end

        group :advanced do
          fields [:parent_comment_id]

          ui do
            label fn -> dgettext("mishka_gervaz", "Advanced") end
            columns 2
          end
        end
      end

      hooks do
        on_cancel fn state -> state end
      end
    end
  end

  guardedstruct do
    auto_wire true

    field :content, :string, derives: "sanitize(basic_html) validate(string, not_empty)"

    field :status, :atom, derives: "validate(atom, enum=Atom[pending::approved::flagged::spam])"

    field :sender_data, :map, derives: "validate(optional=[map])"
    field :is_pinned, :boolean, derives: "validate(boolean)"
    field :site_id, :uuid, derives: "validate(optional=[uuid])"
  end

  # WHO may read which FIELD of a comment they can see. Ash requires that once any field policy
  # exists, every field is covered — hence the `:*` catch-all.
  field_policies do
    field_policy :sender_data do
      description "The sender's IP address and browser are for moderators only"

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:comment", "admin:api:blog:comment"]}
    end

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
      validate present([:post_id])
      validate present([:content])
      validate present([:status])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_comment_id,
                resource: MishkaBlog.Comment,
                message:
                  dgettext_noop(
                    "errors",
                    "Parent comment not found or does not belong to your site."
                  )}

      # Auto-set site_id from the tenant context
      change fn changeset, context ->
        Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
      end

      change relate_actor(:author, allow_nil?: true)

      description "Creates a new comment within tenant context"
    end

    create :master_create do
      description "Creates a comment for master users - bypasses multi-tenancy"
      accept @admin_fields
      multitenancy :bypass

      validate present([:post_id])
      validate present([:content])
      validate present([:status])
      validate present([:site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    create :create_public do
      description "Creates a public comment (user-facing action)"
      accept [:post_id, :content, :parent_comment_id]

      change set_attribute(:status, :pending)
      change relate_actor(:author)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}

      # A post its actor may not open takes nothing from them, as though it were not there.
      validate {MishkaBlog.Resources.Validations.OpenToActor,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                lock: :effective_permissions,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")}

      # Auto-set site_id from tenant
      change fn changeset, context ->
        Ash.Changeset.force_change_attribute(changeset, :site_id, context.tenant)
      end

      # before/reject seam: a plugin can sanitize the changeset or add_error to reject the comment.
      change MishkaCmsCore.Runtime.Resources.Changes.PluginBeforeHook

      validate fn changeset, context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_comment_id)
        post_id = Ash.Changeset.get_attribute(changeset, :post_id)

        if parent_id do
          case Ash.get(MishkaBlog.Comment, parent_id, tenant: context.tenant, authorize?: false) do
            {:ok, parent} when parent.post_id == post_id ->
              :ok

            {:ok, _} ->
              {:error,
               field: :parent_comment_id,
               message: dgettext_noop("errors", "Parent comment must belong to the same post.")}

            _ ->
              {:error,
               field: :parent_comment_id,
               message: dgettext_noop("errors", "Parent comment not found.")}
          end
        else
          :ok
        end
      end
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :post_id,
                resource: MishkaBlog.BlogPost,
                message:
                  dgettext_noop("errors", "Post not found or does not belong to your site.")},
               where: [changing(:post_id)]

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantIsolation,
                field: :parent_comment_id,
                resource: MishkaBlog.Comment,
                message:
                  dgettext_noop(
                    "errors",
                    "Parent comment not found or does not belong to your site."
                  )},
               where: [changing(:parent_comment_id)]

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived comment. Please unarchive it first."
                )
      end

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_comment_id)
        comment_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == comment_id do
          {:error,
           field: :parent_comment_id,
           message: dgettext_noop("errors", "Comment cannot be its own parent.")}
        else
          :ok
        end
      end

      description "Updates an existing comment"
    end

    read :my_comments do
      description "Reads all comments by the authenticated user"
      filter expr(author_id == ^actor(:id))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :approved_by_post do
      description "Reads all approved comments for a specific post (public)"
      argument :post_id, :uuid, allow_nil?: false
      filter expr(post_id == ^arg(:post_id) and status == :approved)

      prepare {MishkaBlog.Resources.Preparations.OpenToActor, kind: :comment}

      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
    end

    read :public_list do
      description "Public endpoint to list all approved comments (no authentication required)"
      prepare MishkaCmsCore.Runtime.Resources.Preparations.PluginQueryHook
      filter expr(status == :approved)

      pagination offset?: true,
                 default_limit: 20,
                 max_page_size: 100,
                 countable: true,
                 required?: false
    end

    read :public_get do
      description "Public endpoint to get a single approved comment by ID (no authentication required)"
      get? true
      filter expr(status == :approved)
    end

    read :master_read do
      description "Reads all comments system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    # The comment in whatever state it is in, archived included, of the site asked for. The rows that
    # point at a comment read it through their `comment_in_any_state` relationship to tell its site.
    read :any_state do
      description "Reads a comment in any state, archived included, of the site asked for"
    end

    read :master_get do
      description "Gets a single comment by ID, bypassing tenant filtering (master users only)"
      get? true
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_archived do
      description "Reads all archived comments system-wide (master users only)"
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get_archived do
      description "Gets a single archived comment by ID (master users only)"
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      description "Lists archived comments"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))
      description "Retrieves single archived comment for recovery or inspection"
    end

    update :approve do
      accept []
      require_atomic? false
      change set_attribute(:status, :approved)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Approves a comment for public display"
    end

    update :flag do
      accept []
      require_atomic? false
      change set_attribute(:status, :flagged)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Flags a comment for review"
    end

    update :mark_spam do
      accept []
      require_atomic? false
      change set_attribute(:status, :spam)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Marks a comment as spam"
    end

    update :pin do
      accept []
      require_atomic? false
      change set_attribute(:is_pinned, true)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Pins a comment to highlight it"
    end

    update :unpin do
      accept []
      require_atomic? false
      change set_attribute(:is_pinned, false)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Unpins a comment"
    end

    destroy :destroy do
      description "Soft deletes comment by archiving"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Comment is already archived.")}
        else
          :ok
        end
      end
    end

    update :unarchive do
      accept []
      require_atomic? false
      change set_attribute(:archived_at, nil)
      atomic_upgrade_with :archived

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Restores archived comment"
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Permanently removes comment and version history from database - use with extreme caution"
    end

    # Master standard actions for cross-tenant management
    update :master_update do
      description "Updates comment for master users - bypasses multi-tenancy"
      require_atomic? false
      transaction? true
      accept [:content, :status, :sender_data, :is_pinned, :parent_comment_id]
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived comment. Please unarchive it first."
                )
      end

      validate fn changeset, _context ->
        parent_id = Ash.Changeset.get_attribute(changeset, :parent_comment_id)
        comment_id = changeset.data.id

        if !is_nil(parent_id) and parent_id == comment_id do
          {:error,
           field: :parent_comment_id,
           message: dgettext_noop("errors", "Comment cannot be its own parent.")}
        else
          :ok
        end
      end
    end

    destroy :master_destroy do
      description "Soft deletes comment by archiving (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at, message: dgettext_noop("errors", "Comment is already archived.")}
        else
          :ok
        end
      end
    end

    update :master_unarchive do
      description "Restores archived comment (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate present(:archived_at) do
        message dgettext_noop("errors", "Comment is not archived.")
      end

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :master_archived
    end

    destroy :master_permanent_destroy do
      description "Permanently deletes comment (master users) - bypasses multi-tenancy"
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    update :master_approve do
      description "Approves comment (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:status, :approved)
    end

    update :master_flag do
      description "Flags comment (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:status, :flagged)
    end

    update :master_mark_spam do
      description "Marks comment as spam (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:status, :spam)
    end

    update :master_pin do
      description "Pins comment (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:is_pinned, true)
    end

    update :master_unpin do
      description "Unpins comment (master users) - bypasses multi-tenancy"
      accept []
      require_atomic? false
      multitenancy :bypass

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:is_pinned, false)
    end
  end

  # Authorization policies for comment access
  #
  # A comment reached through a post follows the read action of the relationship it came through,
  # never the post it hangs off: `BlogPost.comments` reads `:public_list` (approved only, anyone),
  # `BlogPost.tenant_comments` and `BlogPost.master_comments` read every status and fall to the
  # admin policy at the bottom. JSON:API includes are resource-wide, so the admin relationships are
  # offered on the public post routes too, and this is what refuses them there.
  policies do
    # Allow public access to approved comments
    bypass action(:public_list) do
      authorize_if always()
    end

    bypass action(:public_get) do
      authorize_if always()
    end

    # Allow anyone to read approved comments on posts (public commenting)
    bypass action(:approved_by_post) do
      authorize_if always()
    end

    # Allow authenticated users to create comments
    bypass action(:create_public) do
      authorize_if actor_present()
    end

    # Allow users to read their own comments
    bypass action(:my_comments) do
      authorize_if actor_present()
    end

    # Admin access for all actions
    policy always() do
      access_type :strict

      authorize_if {MishkaCmsCore.Accounts.Checks.AccessPermissions,
                    permissions: ["admin:dashboard:blog:comment", "admin:api:blog:comment"]}
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
    prefix "comment"

    # Tenant actions
    publish :create, [[nil, :site_id], "created"]
    publish :create_public, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :approve, [[nil, :site_id], "updated"]
    publish :flag, [[nil, :site_id], "updated"]
    publish :mark_spam, [[nil, :site_id], "updated"]
    publish :pin, [[nil, :site_id], "updated"]
    publish :unpin, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]

    # Master actions
    publish :master_create, [[nil, :site_id], "created"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :master_approve, [[nil, :site_id], "updated"]
    publish :master_flag, [[nil, :site_id], "updated"]
    publish :master_mark_spam, [[nil, :site_id], "updated"]
    publish :master_pin, [[nil, :site_id], "updated"]
    publish :master_unpin, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # A comment names only records of its own site that are not archived, and a user of its own site
  # or a master, whoever writes it. Checked when the id changes, so any other update keeps its
  # atomic path.
  validations do
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :post_id,
              resource: MishkaBlog.BlogPost,
              label: dgettext_noop("errors", "post"),
              read_action: :read_any},
             where: [changing(:post_id)]

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :parent_comment_id,
              resource: MishkaBlog.Comment,
              label: dgettext_noop("errors", "parent comment"),
              read_action: :master_read},
             where: [changing(:parent_comment_id)]

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :author_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "author"),
              shared?: true,
              read_action: :related},
             where: [changing(:author_id)]

    # A create's before-action hooks, a plugin's among them, run after the checks above, so what
    # they write is checked again just before the insert.
    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :post_id,
              resource: MishkaBlog.BlogPost,
              label: dgettext_noop("errors", "post"),
              read_action: :read_any},
             on: [:create],
             before_action?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :parent_comment_id,
              resource: MishkaBlog.Comment,
              label: dgettext_noop("errors", "parent comment"),
              read_action: :master_read},
             on: [:create],
             before_action?: true

    validate {MishkaCmsCore.Runtime.Resources.Validations.SameSiteReference,
              field: :author_id,
              resource: MishkaCmsCore.Accounts.User,
              label: dgettext_noop("errors", "author"),
              shared?: true,
              read_action: :related},
             on: [:create],
             before_action?: true
  end

  # Multi-tenancy configuration - comments are site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :content, :string do
      allow_nil? false
      public? true
      description "Content of the comment"
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :approved, :flagged, :spam]
      description "Moderation status of the comment"
    end

    attribute :sender_data, :map do
      allow_nil? true
      public? true
      default %{}

      constraints fields: [
                    ip_address: [
                      type: :string,
                      allow_nil?: true
                    ],
                    user_agent: [
                      type: :string,
                      allow_nil?: true
                    ]
                  ]

      description "Metadata about the comment sender (IP address, user agent)"
    end

    attribute :is_pinned, :boolean do
      default false
      public? true
      description "Whether the comment is pinned for visibility"
    end

    attribute :site_id, :uuid do
      allow_nil? false
      public? true
      description "The site this comment belongs to (multi-tenancy)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this comment belongs to"
    end

    belongs_to :post, MishkaBlog.BlogPost do
      allow_nil? false
      public? true

      description "The blog post this comment belongs to"
    end

    belongs_to :master_post, MishkaBlog.BlogPost do
      source_attribute :post_id
      define_attribute? false
      public? true
      read_action :read_any
      description "The blog post this comment belongs to (master access, bypasses tenancy)"
      filter expr(not is_nil(type(^actor(:id), :uuid)) and is_nil(type(^actor(:site_id), :uuid)))
    end

    belongs_to :author, MishkaCmsCore.Accounts.User do
      # How any resource reaches an account — see `MishkaCmsCore.Accounts.User`'s `:related`.
      read_action :related
      sortable? false
      allow_nil? true
      public? true

      domain MishkaCmsCore.Accounts
      description "The user who wrote this comment (null for guest comments)"
    end

    has_one :author_profile, MishkaBlog.Blogger do
      public? true
      source_attribute :author_id
      destination_attribute :user_id
      read_action :comment_author
      filter expr(site_id == parent(site_id))

      description "The author's public blogger profile, the way a public page names them (null when they have none)"
    end

    belongs_to :parent_comment, MishkaBlog.Comment do
      allow_nil? true
      public? true

      description "Parent comment for threaded replies"
    end

    has_many :replies, MishkaBlog.Comment do
      public? true
      destination_attribute :parent_comment_id
      description "Child comments replying to this comment"
    end

    has_many :votes, MishkaBlog.CommentVote do
      public? true
      destination_attribute :comment_id
      description "Votes (upvote/downvote) on this comment"
    end
  end

  calculations do
    # Who may reach the comment: whoever may open its post.
    calculate :effective_permissions,
              {:array, :string},
              {MishkaBlog.Resources.Calculations.EffectivePermissions, kind: :comment}

    # the_content / onContentPrepare equivalent for comment bodies.
    calculate :rendered_content,
              :string,
              {MishkaCmsCore.Runtime.Resources.Calculations.RenderContent, source: :content}

    calculate :author_master?,
              :boolean,
              {MishkaCmsCore.Accounts.Calculations.ByMaster, field: :author_id} do
      description "Whether the author is a master, for a reader who cannot load a master's account"
    end
  end

  aggregates do
    count :upvote_count, :votes do
      public? true
      filter expr(vote_type == :up)
    end

    count :downvote_count, :votes do
      public? true
      filter expr(vote_type == :down)
    end
  end
end
