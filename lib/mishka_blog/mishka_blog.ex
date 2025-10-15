defmodule MishkaBlog do
  use Ash.Domain,
    otp_app: :mishka_blog,
    validate_config_inclusion?: false,
    extensions: [
      AshPaperTrail.Domain,
      AshJsonApi.Domain,
      MishkaGervaz.Domain
    ]

  use MishkaGervaz.Messages, backend: MishkaCmsCore.Gettext

  paper_trail do
    include_versions? true
  end

  json_api do
    open_api do
      tag "MishkaBlog"
      group_by :domain
    end

    routes do
    end
  end

  mishka_gervaz do
    table do
      actor_key :current_user
      ui_adapter MishkaGervaz.UIAdapters.Tailwind

      pagination do
        type :load_more
        page_size 20
        page_size_options [20, 50, 100, 150]
      end

      realtime do
        pubsub MishkaCmsCore.PubSub
      end

      actions do
        read {:master_read, :read}
        get {:master_get, :read}
        destroy {:master_destroy, :destroy}
      end

      archive do
        read_action {:master_archived, :archived}
        get_action {:master_get_archived, :get_archived}
        restore_action {:master_unarchive, :unarchive}
        destroy_action {:master_permanent_destroy, :permanent_destroy}
      end
    end

    form do
      actions do
        create {:master_create, :create}
        update {:master_update, :update}
        read {:master_get, :read}
      end

      submit do
        create label: fn -> dgettext("mishka_gervaz", "Create") end
        update label: fn -> dgettext("mishka_gervaz", "Save Changes") end
        cancel label: fn -> dgettext("mishka_gervaz", "Cancel") end
        position :bottom
      end
    end
  end

  resources do
  end
end
