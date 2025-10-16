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
end
