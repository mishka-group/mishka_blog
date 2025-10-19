defmodule MishkaBlog.Dev.Generator do
  @moduledoc """
  Generator for MishkaBlog resources.
  - Test functions (no prefix): simple, deterministic — used by factory and tests.
  - Dev functions (dev_ prefix): realistic, rich data — used by dev seeds.
  """
  use Ash.Generator

  # ---------------------------------------------------------------------------
  # TEST generators
  # ---------------------------------------------------------------------------

  def collection(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Collection,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Collection #{&1}"),
        slug: sequence(:slug, &"test-collection-#{&1}"),
        description: sequence(:description, &"Test collection description #{&1}"),
        status: StreamData.member_of([:active, :draft, :archived]),
        schema: [],
        seo_tags: [],
        featured: false,
        display_order: 0,
        language: "en",
        language_group_id: nil,
        parent_collection_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def blog_post(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.BlogPost,
      :create,
      authorize?: false,
      defaults: [
        title: sequence(:title, &"Test Blog Post #{&1}"),
        slug: sequence(:slug, &"test-blog-post-#{&1}"),
        content: sequence(:content, &"<p>Test blog post content #{&1}</p>"),
        excerpt: sequence(:excerpt, &"Test blog post excerpt #{&1}"),
        featured_image_url: nil,
        status: :draft,
        published_at: nil,
        scheduled_publish_at: nil,
        schema: [],
        seo_tags: [],
        featured: false,
        language: "en",
        language_group_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def blogger(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Blogger,
      :create,
      authorize?: false,
      defaults: [
        user_id: nil,
        display_name: sequence(:display_name, &"Test Blogger #{&1}"),
        slug: sequence(:slug, &"test-blogger-#{&1}"),
        bio: sequence(:bio, &"Test bio for blogger #{&1}"),
        avatar_url: nil,
        cover_image_url: nil,
        expertise_areas: [],
        social_links: [],
        contact_email: nil,
        can_publish_directly: false,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def team(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Team,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Team #{&1}"),
        slug: sequence(:slug, &"test-team-#{&1}"),
        description: sequence(:description, &"Test description for team #{&1}"),
        avatar_url: nil,
        cover_image_url: nil,
        status: :draft,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def team_member(opts \\ []) do
    changeset_generator(
      MishkaBlog.TeamMember,
      :assign,
      authorize?: false,
      defaults: [
        team_id: nil,
        blogger_id: nil,
        role: nil
      ],
      overrides: opts
    )
  end

  def team_permission(opts \\ []) do
    changeset_generator(
      MishkaBlog.TeamPermission,
      :assign,
      authorize?: false,
      defaults: [
        team_id: nil,
        permission_id: nil
      ],
      overrides: opts
    )
  end

  def auto_posting(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.AutoPosting,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Auto Posting #{&1}"),
        plugin: sequence(:plugin, &"test_plugin_#{&1}"),
        description: sequence(:description, &"Test auto posting description #{&1}"),
        is_active: false,
        config: %{},
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def post_blogger(opts \\ []) do
    changeset_generator(
      MishkaBlog.PostBlogger,
      :assign,
      authorize?: false,
      defaults: [
        post_id: nil,
        blogger_id: nil,
        role: nil
      ],
      overrides: opts
    )
  end

  def post_bookmark(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaBlog.PostBookmark,
      :create,
      authorize?: false,
      defaults: [
        post_id: nil,
        user_id: nil
      ],
      overrides: opts,
      actor: actor
    )
  end

  def post_collection(opts \\ []) do
    changeset_generator(
      MishkaBlog.PostCollection,
      :assign,
      authorize?: false,
      defaults: [
        post_id: nil,
        collection_id: nil
      ],
      overrides: opts
    )
  end

  def post_rating(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaBlog.PostRating,
      :create,
      authorize?: false,
      defaults: [
        post_id: nil,
        user_id: nil,
        rating: StreamData.integer(1..5)
      ],
      overrides: opts,
      actor: actor
    )
  end

  def tag(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Tag,
      :create,
      authorize?: false,
      defaults: [
        name: sequence(:name, &"Test Tag #{&1}"),
        slug: sequence(:slug, &"test-tag-#{&1}"),
        description: sequence(:description, &"Test tag description #{&1}"),
        language: "en",
        language_group_id: nil,
        parent_tag_id: nil,
        site_id: nil
      ],
      overrides: opts,
      tenant: tenant
    )
  end

  def post_tag(opts \\ []) do
    changeset_generator(
      MishkaBlog.PostTag,
      :assign,
      authorize?: false,
      defaults: [
        post_id: nil,
        tag_id: nil
      ],
      overrides: opts
    )
  end

  def post_view(opts \\ []) do
    changeset_generator(
      MishkaBlog.PostView,
      :create,
      authorize?: false,
      defaults: [
        post_id: nil,
        user_id: nil,
        ip_address: sequence(:ip_address, &"192.168.1.#{rem(&1, 255)}"),
        user_agent: "Mozilla/5.0 Test Browser",
        referer: nil
      ],
      overrides: opts
    )
  end

  def comment(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Comment,
      :create,
      authorize?: false,
      tenant: tenant,
      defaults: [
        post_id: nil,
        author_id: nil,
        parent_comment_id: nil,
        content: sequence(:comment_content, &"This is test comment content number #{&1}"),
        status: :pending,
        sender_data: %{},
        is_pinned: false
      ],
      overrides: opts
    )
  end

  def comment_vote(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaBlog.CommentVote,
      :create,
      authorize?: false,
      defaults: [
        comment_id: nil,
        user_id: nil,
        vote_type: StreamData.member_of([:up, :down])
      ],
      overrides: opts,
      actor: actor
    )
  end
end
