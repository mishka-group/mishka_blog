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
      base_route "/v1/master/admin/mishka-blog/collection", MishkaBlog.Collection do
        index :master_read
        get :master_read
        index :master_language_variants, route: "/language-variants"
        index :master_archived, route: "/archived"
        get :master_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get

        get :master_get_with_versions, route: "/:id/with-versions"
        index :master_list_versions, route: "/:collection_id/versions"

        patch :master_restore_version_api,
          route: "/:id/version/:version_id/restore"

        get :master_preview_version, route: "/:collection_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/mishka-blog/collection", MishkaBlog.Collection do
        index :read
        get :read
        index :language_variants, route: "/language-variants"
        index :archived, route: "/archived"
        get :archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:collection_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:collection_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/mishka-blog/post", MishkaBlog.BlogPost do
        index :master_read
        get :master_read
        index :master_language_variants, route: "/language-variants"
        index :master_archived, route: "/archived"
        get :master_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_publish, route: "/:id/publish", read_action: :master_get
        patch :master_unpublish, route: "/:id/unpublish", read_action: :master_get
        patch :master_schedule, route: "/:id/schedule", read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get

        get :master_get_with_versions, route: "/:id/with-versions"
        index :master_list_versions, route: "/:post_id/versions"

        patch :master_restore_version_api,
          route: "/:id/version/:version_id/restore"

        get :master_preview_version, route: "/:post_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/mishka-blog/post", MishkaBlog.BlogPost do
        index :read
        get :read
        index :published, route: "/published"
        index :drafts, route: "/drafts"
        index :scheduled, route: "/scheduled"
        index :featured, route: "/featured"
        index :language_variants, route: "/language-variants"
        index :archived, route: "/archived"
        get :archived, route: "/archived/:id"
        post :create
        patch :update
        patch :publish, route: "/:id/publish"
        patch :unpublish, route: "/:id/unpublish"
        patch :schedule, route: "/:id/schedule"
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:post_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:post_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/mishka-blog/blogger", MishkaBlog.Blogger do
        index :master_read
        get :master_read
        get :master_by_user, route: "/by-user/:user_id"
        get :master_by_slug, route: "/by-slug/:slug"
        index :master_archived, route: "/archived"
        get :master_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get

        get :master_get_with_versions, route: "/:id/with-versions"
        index :master_list_versions, route: "/:blogger_id/versions"

        patch :master_restore_version_api,
          route: "/:id/version/:version_id/restore"

        get :master_preview_version, route: "/:blogger_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/mishka-blog/blogger", MishkaBlog.Blogger do
        index :read
        get :read
        get :by_user, route: "/by-user/:user_id"
        get :by_slug, route: "/by-slug/:slug"
        index :archived, route: "/archived"
        get :archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:blogger_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:blogger_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/mishka-blog/tag", MishkaBlog.Tag do
        index :master_read
        get :master_read
        index :master_language_variants, route: "/language-variants"
        index :master_archived, route: "/archived"
        get :master_archived, route: "/archived/:id"
        post :master_create
        patch :master_update, read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get

        get :master_get_with_versions, route: "/:id/with-versions"
        index :master_list_versions, route: "/:tag_id/versions"

        patch :master_restore_version_api,
          route: "/:id/version/:version_id/restore"

        get :master_preview_version, route: "/:tag_id/version/:version_id/preview"
      end

      base_route "/v1/tenant/admin/mishka-blog/tag", MishkaBlog.Tag do
        index :read
        get :read
        index :language_variants, route: "/language-variants"
        index :archived, route: "/archived"
        get :archived, route: "/archived/:id"
        post :create
        patch :update
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"

        get :get_with_versions, route: "/:id/with-versions"
        index :list_versions, route: "/:tag_id/versions"
        patch :restore_version_api, route: "/:id/version/:version_id/restore"
        get :preview_version, route: "/:tag_id/version/:version_id/preview"
      end

      base_route "/v1/master/admin/mishka-blog/comment", MishkaBlog.Comment do
        index :master_read
        get :master_read
        index :master_archived, route: "/archived"
        get :master_archived, route: "/archived/:id"
        patch :master_update, read_action: :master_get
        patch :master_approve, route: "/:id/approve", read_action: :master_get
        patch :master_flag, route: "/:id/flag", read_action: :master_get
        patch :master_mark_spam, route: "/:id/mark-spam", read_action: :master_get
        patch :master_pin, route: "/:id/pin", read_action: :master_get
        patch :master_unpin, route: "/:id/unpin", read_action: :master_get
        patch :master_unarchive, route: "/:id/unarchive", read_action: :master_get_archived
        delete :master_destroy, route: "/:id/archive", read_action: :master_get
        delete :master_permanent_destroy, route: "/:id/permanent", read_action: :master_get
      end

      base_route "/v1/tenant/admin/mishka-blog/comment", MishkaBlog.Comment do
        index :read
        get :read
        index :archived, route: "/archived"
        get :archived, route: "/archived/:id"
        post :create
        patch :update
        patch :approve, route: "/:id/approve"
        patch :flag, route: "/:id/flag"
        patch :mark_spam, route: "/:id/mark-spam"
        patch :pin, route: "/:id/pin"
        patch :unpin, route: "/:id/unpin"
        patch :unarchive, route: "/:id/unarchive", read_action: :get_archived
        delete :destroy, route: "/:id/archive"
        delete :permanent_destroy, route: "/:id/permanent"
      end

      base_route "/v1/user/mishka-blog/post-rating", MishkaBlog.PostRating do
        index :my_ratings, route: "/my-ratings"
        post :create
        delete :remove
      end

      base_route "/v1/user/mishka-blog/comment", MishkaBlog.Comment do
        index :my_comments, route: "/my-comments"
        index :approved_by_post, route: "/approved"
        post :create_public, route: "/create"
      end

      base_route "/v1/user/mishka-blog/comment-vote", MishkaBlog.CommentVote do
        index :my_votes, route: "/my-votes"
        post :create
        delete :remove
      end

      base_route "/v1/user/mishka-blog/post", MishkaBlog.BlogPost do
        index :public_list, route: "/published"
        get :public_get, route: "/published/:id"
      end

      base_route "/v1/user/mishka-blog/collection", MishkaBlog.Collection do
        index :public_list, route: "/active"
        get :public_get, route: "/active/:id"
      end

      base_route "/v1/user/mishka-blog/tag", MishkaBlog.Tag do
        index :public_list
        get :public_get, route: "/:id"
      end

      base_route "/v1/user/mishka-blog/blogger", MishkaBlog.Blogger do
        index :public_list
        get :public_get, route: "/:id"
        get :public_by_slug, route: "/by-slug/:slug"
      end
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
    resource MishkaBlog.Collection
    resource MishkaBlog.BlogPost
    resource MishkaBlog.PostCollection
    resource MishkaBlog.Tag
    resource MishkaBlog.PostTag
    resource MishkaBlog.PostRating
    resource MishkaBlog.PostView
    resource MishkaBlog.Blogger
    resource MishkaBlog.PostBlogger
    resource MishkaBlog.Comment
    resource MishkaBlog.CommentVote
  end
end
