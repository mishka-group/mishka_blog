# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.AutoPosting do
  @moduledoc """
  Manages auto-posting configurations in the MishkaBlog plugin with full versioning support.

  This resource represents auto-posting configurations that enable automated publishing
  of blog posts to external platforms (social media, newsletters, etc.). Each configuration
  belongs to a specific site and plugin, defining how and when content should be
  automatically distributed.

  Auto-posting configurations feature full version control through PaperTrail integration,
  tracking all changes with snapshot-based history including configuration updates
  and activation toggles. The resource implements soft deletion via archival and
  provides comprehensive configuration management through flexible key-value storage.

  The config field uses a map structure where each key represents a configuration
  parameter with metadata about its type, value, and help text. This allows plugins
  to define their own configuration schemas dynamically while maintaining a consistent
  interface for administration.

  The unique constraint on plugin and site_id ensures each plugin has only one
  configuration per site. Database-level constraints ensure data integrity and
  prevention of modifications to archived configurations. Multi-tenant isolation
  ensures configurations are properly segregated between sites.
  """
  use Ash.Resource,
    otp_app: :mishka_blog,
    domain: MishkaBlog,
    data_layer: AshPostgres.DataLayer,
    extensions: [
      AshArchival.Resource,
      AshPaperTrail.Resource,
      AshJsonApi.Resource,
      MishkaGervaz.Resource,
      GuardedStruct.AshResource
    ],
    notifiers: [Ash.Notifier.PubSub, MishkaCmsCore.Runtime.Resources.Notifiers.PluginHook],
    authorizers: [Ash.Policy.Authorizer]

  import Phoenix.Component, only: [sigil_H: 2]
  import MishkaGervaz.UIAdapters.Tailwind, only: [cell_stacked: 1, cell_stats: 1]
  require Ash.Query
  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  # The 33-tir action square, shared by every row action so a hover tint is the only thing that
  # varies. Icon-only: the label still reaches the DOM as the button's `title` and a hidden `.lbl`.
  @square "grid size-[30px] flex-none place-items-center rounded-[8px] border transition-colors " <>
            "[&_.lbl]:hidden [&>span:not(.lbl)]:size-[15px]!"

  @square_action @square <>
                   " border-[#ecebe6] bg-[#faf9f6] text-[#5c5a54] hover:bg-[#f2f1fc] hover:text-[#4f4bcc]"

  @square_versions @square <>
                     " border-[#ecebe6] bg-[#faf9f6] text-[#7a5bd0] hover:bg-[#f4ecfb]"

  @square_go @square <> " border-[#cfe8db] bg-[#f1f9f4] text-[#177a53] hover:bg-[#e6f6ee]"
  @square_pause @square <> " border-[#f0e4c8] bg-[#fbf6ea] text-[#a5691a] hover:bg-[#fbf1df]"
  @square_danger @square <> " border-[#f0dcd8] bg-[#fdf3f1] text-[#c0473d] hover:bg-[#fbe9e7]"

  @square_roadmap @square <>
                    " pointer-events-none border-[#ecebe6] bg-[#faf9f6] text-[#bcb9b2] opacity-60"

  @admin_fields [
    :name,
    :plugin,
    :description,
    :is_active,
    :config,
    :site_id
  ]

  # Database configuration for auto_posting storage with indexing
  postgres do
    table "mishka_blog_auto_postings"
    repo Application.compile_env!(:mishka_cms_core, :repo)

    references do
      reference :site, on_delete: :delete
    end

    # Database-level optimization for archived records
    base_filter_sql "(archived_at IS NULL)"

    custom_indexes do
      index [:is_active]
    end

    check_constraints do
      check_constraint :name, "name_length",
        check: "length(name) >= 1 AND length(name) <= 255",
        message: dgettext_noop("errors", "Name must be between 1 and 255 characters.")

      check_constraint :plugin, "plugin_length",
        check: "length(plugin) >= 1 AND length(plugin) <= 255",
        message: dgettext_noop("errors", "Plugin must be between 1 and 255 characters.")
    end

    # Database-level trigger to prevent updates on archived records
    custom_statements do
      statement :prevent_archived_auto_posting_updates_function do
        up """
        CREATE OR REPLACE FUNCTION prevent_archived_auto_posting_updates()
        RETURNS TRIGGER AS $$
        BEGIN
          -- Allow unarchiving (archived_at: NOT NULL -> NULL)
          IF OLD.archived_at IS NOT NULL AND NEW.archived_at IS NULL THEN
            RETURN NEW;
          END IF;

          -- Prevent other updates on archived records
          IF OLD.archived_at IS NOT NULL THEN
            RAISE EXCEPTION 'Cannot update archived auto-posting configuration'
              USING ERRCODE = 'check_violation';
          END IF;

          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
        """

        down "DROP FUNCTION IF EXISTS prevent_archived_auto_posting_updates();"
      end

      statement :prevent_archived_auto_posting_updates_trigger do
        up """
        CREATE TRIGGER prevent_archived_auto_posting_updates_trigger
          BEFORE UPDATE ON mishka_blog_auto_postings
          FOR EACH ROW
          EXECUTE FUNCTION prevent_archived_auto_posting_updates();
        """

        down "DROP TRIGGER IF EXISTS prevent_archived_auto_posting_updates_trigger ON mishka_blog_auto_postings;"
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

  # Version control configuration for full auto-posting history tracking
  paper_trail do
    primary_key_type :uuid_v7
    change_tracking_mode :snapshot
    store_action_name? true
    store_action_inputs? true
    ignore_attributes [:inserted_at, :updated_at, :archived_at]
    ignore_actions [:unarchive, :master_unarchive, :permanent_destroy, :master_permanent_destroy]
    attributes_as_attributes [:site_id]
    create_version_on_destroy? true
    only_when_changed? true
    relationship_opts public?: true

    # The version stays, with no author, when the account that made it is deleted.
    belongs_to_actor :user, MishkaCmsCore.Accounts.User,
      domain: MishkaCmsCore.Accounts,
      on_delete: :nilify

    version_extensions authorizers: [Ash.Policy.Authorizer]

    mixin {MishkaBlog.Resources.Mixins.AutoPostingPaperTrailMixin, :postgres, []}
  end

  # JSON API configuration for REST endpoints
  json_api do
    type "auto_posting"
  end

  # MishkaGervaz table configuration for admin UI
  mishka_gervaz do
    table do
      identity do
        name :auto_postings
        route "/admin/dashboard/blog/auto-postings"
        stream_name :auto_postings
      end

      source do
        preload do
          always [:site, :version_count]
        end
      end

      columns do
        # The name is the row's headline; the plugin identifier rides beneath it in mono, the way a
        # slug sits under a title elsewhere, with a copy button since a plugin key is pasted into
        # config far more often than it is read.
        column :name do
          static true
          requires [:id, :name, :plugin]
          label fn -> dgettext("mishka_gervaz", "Name") end
          sortable true
          sort_field [:name]

          ui do
            width "minmax(190px,1.4fr)"
          end

          render fn record ->
            assigns = %{id: record.id, name: record.name, plugin: record.plugin}

            ~H"""
            <.cell_stacked
              variant={:title}
              primary={@name}
              secondary={@plugin}
              copy={
                %{
                  id: "auto-posting-plugin-copy-#{@id}",
                  value: @plugin,
                  label: dgettext("mishka_gervaz", "Copy plugin")
                }
              }
            />
            """
          end
        end

        column :is_active do
          sortable true
          label fn -> dgettext("mishka_gervaz", "Status") end

          ui do
            type :badge
            width "minmax(96px,0.6fr)"

            extra %{
              colors: %{
                "true" => "bg-[#e6f6ee] text-[#177a53]",
                "false" => "bg-[#f2f1ec] text-[#8a877f]"
              },
              labels: %{
                "true" => dgettext_noop("mishka_gervaz", "Active"),
                "false" => dgettext_noop("mishka_gervaz", "Inactive")
              },
              dots: %{
                "true" => "bg-[#177a53]",
                "false" => "bg-[#a8a5a0]"
              },
              variant: :pill
            }
          end
        end

        # The description is the one cell that grows with its content, so it takes the widest track
        # and clamps to two lines with the full text on hover.
        column :description do
          label fn -> dgettext("mishka_gervaz", "Description") end

          ui do
            width "minmax(210px,1.8fr)"
          end

          render fn value ->
            assigns = %{description: value}

            ~H"""
            <p
              :if={@description}
              class="line-clamp-2 text-[12.5px] leading-[1.5] text-[#6d6a63]"
              title={@description}
            >
              {@description}
            </p>
            <span :if={is_nil(@description)} class="text-[12px] font-medium text-[#a8a5a0]">—</span>
            """
          end
        end

        # Site and date share one cell, as every table on the dashboard draws them: the site name
        # only means something to a master user, so a tenant reader gets the date alone.
        column :site_datetime do
          static true
          requires [:site_id, :site, :inserted_at]
          label fn -> dgettext("mishka_gervaz", "Site / Date") end

          ui do
            width "minmax(140px,1fr)"
          end

          render fn record, state ->
            site_name =
              case record.site do
                %{name: name} -> name
                _unloaded -> nil
              end

            assigns = %{
              site: (state.master_user? && site_name) || nil,
              date: MishkaCmsCore.Localized.date(record.inserted_at, :yMMMd)
            }

            ~H"""
            <.cell_stacked
              variant={:meta}
              icon="hero-server-stack"
              primary={@site || @date}
              secondary={(@site && @date) || nil}
            />
            """
          end
        end

        column :stats_info do
          static true
          requires [:version_count]
          label fn -> dgettext("mishka_gervaz", "Versions") end

          ui do
            width "minmax(90px,0.55fr)"
          end

          render fn record ->
            assigns = %{
              items: [
                %{
                  icon: "hero-clock",
                  value: counted(record.version_count),
                  label: dgettext("mishka_gervaz", "Versions")
                }
              ]
            }

            ~H"""
            <.cell_stats items={@items} />
            """
          end
        end
      end

      filters do
        filter :search, :text, fields: [:name, :plugin, :description]

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

        filter :is_active, :boolean do
          ui do
            label fn -> dgettext("mishka_gervaz", "Active") end
          end
        end
      end

      row_actions do
        action :edit do
          type :event
          event "edit_auto_posting"
          visible :active

          render fn record ->
            roadmap_square(%{
              id: "auto-posting-edit-roadmap-#{record.id}",
              icon: "hero-pencil-square",
              hint: dgettext("mishka_gervaz", "Editing is on our roadmap.")
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Edit") end
            icon "hero-pencil-square"
            class @square_action
          end
        end

        action :versions do
          type :event
          event "show_versions"
          visible :active

          render fn record ->
            roadmap_square(%{
              id: "auto-posting-versions-roadmap-#{record.id}",
              icon: "hero-clock",
              hint: dgettext("mishka_gervaz", "Version history is on our roadmap.")
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Versions") end
            icon "hero-clock"
            class @square_versions
          end
        end

        action :activate do
          type :update
          action {:master_activate, :activate}
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Activate") end
            icon "hero-play"
            class @square_go
          end
        end

        action :deactivate do
          type :update
          action {:master_deactivate, :deactivate}
          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Deactivate") end
            icon "hero-pause"
            class @square_pause
          end
        end

        action :archive do
          type :destroy

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Are you sure you want to archive this auto-posting configuration?"
            )
          end

          visible :active

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete") end
            icon "hero-archive-box"
            class @square_danger
          end
        end

        action :unarchive do
          type :unarchive

          confirm fn _record ->
            dgettext(
              "mishka_gervaz",
              "Are you sure you want to restore this auto-posting configuration?"
            )
          end

          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Restore") end
            icon "hero-arrow-uturn-left"
            class @square_go
          end
        end

        action :versions_archived do
          type :event
          event "show_versions"
          visible :archived

          render fn record ->
            roadmap_square(%{
              id: "auto-posting-versions-archived-roadmap-#{record.id}",
              icon: "hero-clock",
              hint: dgettext("mishka_gervaz", "Version history is on our roadmap.")
            })
          end

          ui do
            label fn -> dgettext("mishka_gervaz", "Versions Archived") end
            icon "hero-clock"
            class @square_versions
          end
        end

        action :permanent_destroy do
          type :permanent_destroy

          confirm dgettext_noop(
                    "mishka_gervaz",
                    "Are you sure you want to PERMANENTLY delete this configuration? This action cannot be undone!"
                  )

          visible :archived

          ui do
            label fn -> dgettext("mishka_gervaz", "Delete Permanently") end
            icon "hero-trash"
            class @square_danger
          end
        end
      end

      row do
        selectable true
      end

      bulk_actions do
        action :archive,
          type: :destroy,
          confirm: dgettext_noop("mishka_gervaz", "Archive selected configurations?")

        action :unarchive,
          type: :unarchive,
          confirm: dgettext_noop("mishka_gervaz", "Restore selected configurations?"),
          visible: :archived

        action :permanent_destroy,
          type: :permanent_destroy,
          confirm:
            dgettext_noop(
              "mishka_gervaz",
              "Permanently delete selected configurations? This cannot be undone."
            ),
          visible: :archived
      end

      realtime do
        prefix "auto_posting"

        visible fn record, user ->
          is_nil(user.site_id) or record.site_id == user.site_id
        end
      end

      url_sync do
        mode :bidirectional
        params [:filters, :sort, :page, :search]
        prefix "auto_postings"
        max_filter_length 500
      end

      empty_state message: dgettext_noop("mishka_gervaz", "No auto-posting configurations found"),
                  icon: "hero-arrow-path"
    end
  end

  guardedstruct do
    auto_wire true

    field :name, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :plugin, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(string, not_empty, min_len=1, max_len=255)"

    field :description, :string,
      validator: {MishkaCmsCore.PlainText, :field},
      derives: "sanitize(trim) validate(optional=[string])"

    field :is_active, :boolean, derives: "validate(boolean)"
    field :config, :map, derives: "validate(optional=[map])"
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

      validate present([:name, :plugin])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change &Ash.Changeset.force_change_attribute(&1, :site_id, &2.tenant)

      description "Creates auto-posting configuration for tenant users - requires tenant context, auto-assigns site_id"
    end

    create :master_create do
      validate present([:name, :plugin, :site_id])

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change fn changeset, _context ->
        site_id = Ash.Changeset.get_attribute(changeset, :site_id)
        Ash.Changeset.set_tenant(changeset, site_id)
      end

      description "Creates auto-posting configuration for master users - bypasses multi-tenancy, requires explicit site_id"
    end

    update :update do
      primary? true
      require_atomic? false
      transaction? true
      accept List.delete(@admin_fields, :site_id)

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived auto-posting configuration. Please unarchive it first."
                )
      end

      description "Updates auto-posting configuration for tenant users - requires tenant context, prevents site_id changes"
    end

    update :master_update do
      description "Updates auto-posting configuration for master users - requires nil tenant context, prevents site_id changes"
      accept List.delete(@admin_fields, :site_id)
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot edit archived auto-posting configuration. Please unarchive it first."
                )
      end
    end

    read :by_plugin do
      description "Reads auto-posting configuration by plugin within current tenant context"
      argument :plugin, :string, allow_nil?: false
      filter expr(plugin == ^arg(:plugin))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_by_plugin do
      multitenancy :bypass
      description "Reads auto-posting configuration by plugin system-wide (master users only)"
      argument :plugin, :string, allow_nil?: false
      filter expr(plugin == ^arg(:plugin))
      get? true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :active do
      description "Reads active auto-posting configurations"
      filter expr(is_active == true)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}
    end

    read :master_active do
      multitenancy :bypass
      description "Reads active auto-posting configurations system-wide (master users only)"
      filter expr(is_active == true)
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_read do
      description "Reads all auto-posting configurations system-wide, bypassing tenant filtering (master users only)"
      multitenancy :bypass
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :master_get do
      multitenancy :bypass
      get? true
      description "Retrieves single auto-posting configuration by ID, bypassing tenant filtering"

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    read :archived do
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Lists archived auto-posting configurations within current tenant context"
    end

    read :get_archived do
      get? true
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Retrieves single archived auto-posting configuration for recovery or inspection (tenant users)"
    end

    read :master_get_archived do
      get? true
      multitenancy :bypass
      filter expr(not is_nil(archived_at))

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Retrieves single archived auto-posting configuration for recovery or inspection (master users)"
    end

    read :master_archived do
      multitenancy :bypass
      filter expr(not is_nil(archived_at))
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      description "Lists all archived auto-posting configurations system-wide, bypassing tenant filtering"
    end

    update :activate do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:is_active, true)

      description "Activates an auto-posting configuration"
    end

    update :master_activate do
      description "Activates an auto-posting configuration (master users)"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:is_active, true)
    end

    update :deactivate do
      accept []
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      change set_attribute(:is_active, false)

      description "Deactivates an auto-posting configuration"
    end

    update :master_deactivate do
      description "Deactivates an auto-posting configuration (master users)"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      change set_attribute(:is_active, false)
    end

    destroy :destroy do
      description "Soft deletes auto-posting configuration by archiving (tenant users)"
      primary? true
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Auto-posting configuration is already archived.")}
        else
          :ok
        end
      end
    end

    destroy :master_destroy do
      description "Soft deletes auto-posting configuration by archiving (master users) - requires nil tenant context"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if changeset.data.archived_at do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Auto-posting configuration is already archived.")}
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

      description "Restores archived auto-posting configuration (tenant users)"
    end

    update :master_unarchive do
      description "Restores archived auto-posting configuration (master users) - requires nil tenant context"
      accept []
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate fn changeset, _context ->
        if is_nil(changeset.data.archived_at) do
          {:error,
           field: :archived_at,
           message: dgettext_noop("errors", "Auto-posting configuration is not archived.")}
        else
          :ok
        end
      end

      change set_attribute(:archived_at, nil)

      atomic_upgrade_with :master_archived
    end

    destroy :permanent_destroy do
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      description "Permanently removes auto-posting configuration and version history from database (tenant users) - use with extreme caution"
    end

    destroy :master_permanent_destroy do
      description "Permanently removes auto-posting configuration and version history from database (master users) - irreversible and extremely dangerous"
      multitenancy :bypass
      require_atomic? false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}
    end

    # Version Management Actions - Tenant

    read :get_with_versions do
      get? true

      description "Gets a single auto-posting configuration with paginated sorted versions (tenant users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.AutoPosting.Version
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

      description "Gets a single auto-posting configuration with paginated sorted versions (master users)"

      argument :versions_limit, :integer, allow_nil?: true, default: 20
      argument :versions_offset, :integer, allow_nil?: true, default: 0

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        versions_limit = Ash.Query.get_argument(query, :versions_limit)
        versions_offset = Ash.Query.get_argument(query, :versions_offset)

        Ash.Query.load(query,
          sorted_versions:
            MishkaBlog.AutoPosting.Version
            |> Ash.Query.new()
            |> Ash.Query.load([:user])
            |> Ash.Query.limit(versions_limit)
            |> Ash.Query.offset(versions_offset)
        )
      end
    end

    read :list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true

      description "List all versions for an auto-posting configuration with pagination (tenant users)"

      argument :auto_posting_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      prepare fn query, context ->
        auto_posting_id = Ash.Query.get_argument(query, :auto_posting_id)

        # Verify the auto-posting belongs to the tenant
        case Ash.get(MishkaBlog.AutoPosting, auto_posting_id, Ash.Scope.to_opts(context)) do
          {:ok, _auto_posting} ->
            query
            |> Ash.Query.filter(id == ^auto_posting_id)
            |> Ash.Query.load(
              sorted_versions:
                MishkaBlog.AutoPosting.Version
                |> Ash.Query.new()
            )

          {:error, _reason} ->
            Ash.Query.add_error(
              query,
              Ash.Error.Query.NotFound.exception(resource: MishkaBlog.AutoPosting)
            )
        end
      end
    end

    read :master_list_versions do
      pagination offset?: true, default_limit: 20, max_page_size: 100, countable: true
      multitenancy :bypass
      description "List all versions for an auto-posting configuration (master users)"

      argument :auto_posting_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      prepare fn query, _context ->
        auto_posting_id = Ash.Query.get_argument(query, :auto_posting_id)

        query
        |> Ash.Query.filter(id == ^auto_posting_id)
        |> Ash.Query.load(
          sorted_versions:
            MishkaBlog.AutoPosting.Version
            |> Ash.Query.new()
        )
      end
    end

    update :restore_version do
      accept []
      require_atomic? false
      description "Restores the auto-posting configuration to a previous version (tenant users)"

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived auto-posting configuration. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.AutoPosting.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "auto-posting configuration")}
    end

    update :master_restore_version do
      description "Restores auto-posting configuration to a previous version (master users)"
      accept []
      multitenancy :bypass
      require_atomic? false

      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      validate absent(:archived_at) do
        message dgettext_noop(
                  "errors",
                  "Cannot restore version of archived auto-posting configuration. Please unarchive it first."
                )
      end

      change {MishkaBlog.Resources.Changes.RestoreVersion,
              version: MishkaBlog.AutoPosting.Version,
              fields: List.delete(@admin_fields, :site_id),
              label: dgettext_noop("errors", "auto-posting configuration")}
    end

    action :restore_version_api, :struct do
      description "Restores auto-posting content from a specific version in history (tenant users - API)"
      constraints instance_of: MishkaBlog.AutoPosting

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run fn input, context ->
        auto_posting_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(
          MishkaBlog.AutoPosting,
          auto_posting_id,
          Ash.Scope.to_opts(context, action: :read)
        )
        |> case do
          {:ok, auto_posting} when not is_nil(auto_posting) ->
            if !is_nil(auto_posting.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived auto-posting. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = auto_posting.site_id

              auto_posting
              |> Ash.Changeset.for_update(
                :restore_version,
                %{version_id: version_id},
                Ash.Scope.to_opts(context, tenant: tenant)
              )
              |> Ash.update()
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.AutoPosting)}
        end
      end
    end

    action :master_restore_version_api, :struct do
      description "Restores auto-posting content from a specific version in history (master users - API)"
      constraints instance_of: MishkaBlog.AutoPosting

      argument :id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run fn input, context ->
        auto_posting_id = input.arguments.id
        version_id = input.arguments.version_id

        Ash.get(
          MishkaBlog.AutoPosting,
          auto_posting_id,
          Ash.Scope.to_opts(context, action: :master_get, tenant: nil)
        )
        |> case do
          {:ok, auto_posting} when not is_nil(auto_posting) ->
            if !is_nil(auto_posting.archived_at) do
              {:error,
               Ash.Error.Invalid.exception(
                 errors: [
                   Ash.Error.Changes.InvalidAttribute.exception(
                     field: :archived_at,
                     message:
                       dgettext_noop(
                         "errors",
                         "Cannot restore version of archived auto-posting. Please unarchive it first."
                       )
                   )
                 ]
               )}
            else
              tenant = auto_posting.site_id

              auto_posting
              |> Ash.Changeset.for_update(
                :restore_version,
                %{version_id: version_id},
                Ash.Scope.to_opts(context, tenant: tenant)
              )
              |> Ash.update()
            end

          _ ->
            {:error, Ash.Error.Query.NotFound.exception(resource: MishkaBlog.AutoPosting)}
        end
      end
    end

    action :preview_version, :struct do
      description "Preview a specific version without restoring (tenant users)"
      constraints instance_of: MishkaBlog.AutoPosting

      argument :auto_posting_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: false}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :auto_posting_id,
           version: MishkaBlog.AutoPosting.Version,
           fields: List.delete(@admin_fields, :site_id),
           label: dgettext_noop("errors", "auto-posting configuration")}
    end

    action :master_preview_version, :struct do
      description "Preview a specific version without restoring (master users)"
      constraints instance_of: MishkaBlog.AutoPosting

      argument :auto_posting_id, :uuid, allow_nil?: false
      argument :version_id, :uuid, allow_nil?: false

      validate {MishkaCmsCore.Runtime.Resources.Validations.TenantContext, require_master: true}

      run {MishkaBlog.Resources.Actions.PreviewVersion,
           record: :auto_posting_id,
           version: MishkaBlog.AutoPosting.Version,
           fields: List.delete(@admin_fields, :site_id),
           master: true,
           label: dgettext_noop("errors", "auto-posting configuration")}
    end
  end

  # Authorization policies for auto-posting access
  policies do
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

  # PubSub notifications for auto-posting changes
  pub_sub do
    module Application.compile_env!(:mishka_cms_core, :endpoint)
    prefix "auto_posting"

    publish :create, [[nil, :site_id], "created"]
    publish :master_create, [[nil, :site_id], "created"]
    publish :update, [[nil, :site_id], "updated"]
    publish :master_update, [[nil, :site_id], "updated"]
    publish :restore_version, [[nil, :site_id], "updated"]
    publish :master_restore_version, [[nil, :site_id], "updated"]
    publish :unarchive, [[nil, :site_id], "updated"]
    publish :master_unarchive, [[nil, :site_id], "updated"]
    publish :destroy, [[nil, :site_id], "destroyed"]
    publish :master_destroy, [[nil, :site_id], "destroyed"]
    publish :permanent_destroy, [[nil, :site_id], "destroyed"]
    publish :master_permanent_destroy, [[nil, :site_id], "destroyed"]
  end

  # Multi-tenancy configuration - auto-posting configurations are always site-specific
  multitenancy do
    strategy :attribute
    attribute :site_id
    # Auto-posting configurations are NEVER global - always site-specific
    global? false
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Name of the auto-posting configuration"
    end

    attribute :plugin, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 255, trim?: true
      description "Plugin identifier (unique per site)"
    end

    attribute :description, :string do
      allow_nil? true
      public? true
      description "Description of what this auto-posting configuration does"
    end

    attribute :is_active, :boolean do
      default false
      public? true
      description "Whether this auto-posting configuration is enabled"
    end

    attribute :config, :map do
      allow_nil? true
      public? true
      default %{}

      description "Plugin-specific configuration as key-value pairs with metadata (field type, value, help text)"
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :site, MishkaCmsCore.Runtime.Site do
      read_action :read_any
      allow_nil? false
      public? true
      description "The site this auto-posting configuration belongs to"
    end

    # Loaded through `:sorted_versions` as whoever runs the read. A version query handed to a load
    # is left unbuilt (`Ash.Query.new/1`) so that this action builds it for that reader.
    has_many :sorted_versions, MishkaBlog.AutoPosting.Version do
      public? true
      source_attribute :id
      destination_attribute :version_source_id
      read_action :sorted_versions
      sort version_inserted_at: :desc
      description "Versions sorted by insertion time (newest first)"
    end
  end

  calculations do
    calculate :version_count, :integer do
      public? true
      description "Counts total number of versions in auto-posting configuration history"

      calculation fn records, context ->
        record_ids = Enum.map(records, & &1.id)

        versions_by_source =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^record_ids)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)

        {:ok,
         Enum.map(records, fn record ->
           length(Map.get(versions_by_source, record.id, []))
         end)}
      end
    end

    calculate :latest_version, :struct do
      public? true
      constraints instance_of: MishkaBlog.AutoPosting.Version
      description "Returns the most recent version of the auto-posting configuration"

      calculation fn records, context ->
        record_ids = Enum.map(records, & &1.id)

        latest_versions =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^record_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)
          |> Map.new(fn {k, v} -> {k, List.first(v)} end)

        {:ok,
         Enum.map(records, fn record ->
           Map.get(latest_versions, record.id)
         end)}
      end
    end

    calculate :recent_versions, {:array, :struct} do
      public? true
      constraints items: [instance_of: MishkaBlog.AutoPosting.Version]
      description "Returns up to 10 most recent versions"

      calculation fn records, context ->
        record_ids = Enum.map(records, & &1.id)

        recent_versions =
          MishkaBlog.AutoPosting.Version
          |> Ash.Query.for_read(:read_any)
          |> Ash.Query.filter(version_source_id in ^record_ids)
          |> Ash.Query.sort(version_inserted_at: :desc)
          |> Ash.read!(Ash.Scope.to_opts(context))
          |> Enum.group_by(& &1.version_source_id)

        {:ok,
         Enum.map(records, fn record ->
           Map.get(recent_versions, record.id, [])
           |> Enum.take(10)
         end)}
      end
    end
  end

  identities do
    identity :unique_plugin_per_site, [:plugin, :site_id] do
      description "Ensures each plugin has only one configuration per site"
      message dgettext_noop("errors", "This plugin already has a configuration for this site.")
      all_tenants? true
      nils_distinct? false
    end
  end

  # version_count is admin-gated, so a viewer the field policy hides it from receives a truthy
  # %Ash.ForbiddenField{}/%Ash.NotLoaded{} rather than a number, which `|| 0` would let through.
  defp counted(value) when is_integer(value) and value >= 0, do: value
  defp counted(_value), do: 0

  defp roadmap_square(assigns) do
    assigns = Map.put(assigns, :class, @square_roadmap)

    ~H"""
    <span class="inline-flex cursor-not-allowed" title={@hint} data-role="roadmap-action">
      <button type="button" id={@id} class={@class} aria-label={@hint} aria-disabled="true" disabled>
        <span class={@icon}></span>
      </button>
    </span>
    """
  end
end
