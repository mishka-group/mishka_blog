# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dev.Generator do
  @moduledoc """
  Generator for MishkaBlog resources.
  - Test functions (no prefix): simple, deterministic — used by factory and tests.
  - Dev functions (dev_ prefix): realistic, rich data — used by dev seeds.
  """
  use Ash.Generator

  @post_titles [
    "Getting Started with Elixir",
    "Phoenix LiveView Deep Dive",
    "Ash Framework in Production",
    "Building Real-Time Apps",
    "Distributed Systems Patterns",
    "OTP Supervision Trees",
    "GenServer Best Practices",
    "Ecto Query Optimization",
    "Testing Strategies in Elixir",
    "Deploying with Fly.io",
    "GraphQL with Absinthe",
    "PostgreSQL Performance Tuning",
    "LiveView Streams and Collections",
    "Pattern Matching Mastery",
    "Metaprogramming in Elixir",
    "WebSockets vs Server-Sent Events",
    "Containerizing Elixir Apps",
    "Observability with Telemetry",
    "Event Sourcing with Ash",
    "Multi-tenancy Architecture"
  ]

  @tag_names [
    "elixir",
    "phoenix",
    "liveview",
    "otp",
    "genserver",
    "ecto",
    "postgresql",
    "ash-framework",
    "distributed-systems",
    "testing",
    "deployment",
    "performance",
    "architecture",
    "metaprogramming",
    "real-time",
    "websockets",
    "observability",
    "multi-tenancy",
    "event-sourcing",
    "graphql"
  ]

  @collection_names [
    "Elixir Fundamentals",
    "Phoenix Framework",
    "OTP Patterns",
    "Database Optimization",
    "Production Deployments",
    "Architecture Series",
    "Testing Best Practices",
    "Performance Tuning",
    "Real-Time Features",
    "Advanced Elixir"
  ]

  @comment_templates [
    "Great article! This really helped me understand the concept.",
    "I've been struggling with this for weeks. Thanks for the clear explanation!",
    "Have you considered using pattern matching instead? It might be cleaner.",
    "This approach worked perfectly for my use case. Thank you!",
    "Could you elaborate on the performance implications?",
    "I found a small typo in the code example, but otherwise excellent content.",
    "This is exactly what I was looking for. Bookmarking this.",
    "I'd love to see a follow-up article on advanced use cases.",
    "The comparison table at the end is very helpful.",
    "I implemented this in my project and it works great!"
  ]

  @team_names [
    "Core Contributors",
    "Technical Writers",
    "Community Team",
    "Review Board",
    "Editorial Team"
  ]

  @team_focus [
    "content creation",
    "technical reviews",
    "community engagement",
    "editorial quality",
    "documentation coverage"
  ]

  @auto_posting_plugins ["twitter", "linkedin", "mastodon", "bluesky", "rss_feed"]

  @user_agents [
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64; rv:127.0) Gecko/20100101 Firefox/127.0",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
  ]

  @post_status_pool [
    :published,
    :published,
    :published,
    :published,
    :published,
    :published,
    :draft,
    :draft,
    :scheduled
  ]

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
        permissions: [],
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
        subtitle: nil,
        featured_image_url: nil,
        status: :draft,
        published_at: nil,
        scheduled_publish_at: nil,
        schema: [],
        seo_tags: [],
        permissions: [],
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

  def blogger_follower(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaBlog.BloggerFollower,
      :create,
      authorize?: false,
      defaults: [
        blogger_id: nil,
        follower_user_id: nil,
        notification_enabled: true
      ],
      overrides: opts,
      actor: actor
    )
  end

  def team_follower(opts \\ [], actor \\ nil) do
    changeset_generator(
      MishkaBlog.TeamFollower,
      :create,
      authorize?: false,
      defaults: [
        team_id: nil,
        follower_user_id: nil,
        notification_enabled: true
      ],
      overrides: opts,
      actor: actor
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
        seo_tags: [],
        permissions: [],
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

  # ---------------------------------------------------------------------------
  # DEV generators (realistic data)
  # ---------------------------------------------------------------------------

  @doc """
  A realistic English blog post whose lifecycle fields agree with its status: published posts carry a
  `published_at` in the last 18 months, drafts carry neither date, and scheduled posts carry only a
  `scheduled_publish_at` 31-45 days out. `:archived` is deliberately absent from the status pool —
  that label is a separate axis from the `archived_at` soft delete and is written explicitly by the
  seeds, never drawn at random.

  A COVER IS PASSED IN, never invented here. This drew one from two hardcoded paths under
  `/images/`, which exist in the host application and in no other project, so the same generator
  wrote a working cover in one repository and a 404 in the next. The seeds hand over a path from the
  site's own media library — see `MishkaBlog.Dev.Seeds` — and `nil` is the common case a post list
  still has to look right without.
  """
  def dev_blog_post(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.BlogPost,
      :create,
      authorize?: false,
      uses: %{
        seq: sequence(:dev_post_seq, & &1),
        status: StreamData.member_of(@post_status_pool),
        paragraphs: StreamData.integer(3..8),
        featured: StreamData.boolean()
      },
      defaults: fn %{
                     seq: seq,
                     status: status,
                     paragraphs: paragraphs,
                     featured: featured
                   } ->
        topic = Enum.at(@post_titles, rem(seq, length(@post_titles)))
        title = "#{topic} — Part #{div(seq, length(@post_titles)) + 1}"
        {published_at, scheduled_publish_at} = post_lifecycle_dates(status)

        [
          title: title,
          slug: "#{to_slug(topic)}-#{seq}",
          content: post_content(topic, paragraphs),
          excerpt:
            "#{topic}. A comprehensive guide covering the essential concepts and practical applications.",
          featured_image_url: nil,
          status: status,
          published_at: published_at,
          scheduled_publish_at: scheduled_publish_at,
          schema: [],
          seo_tags: post_seo_tags(title),
          permissions: [],
          featured: featured,
          language: "en",
          language_group_id: nil,
          site_id: nil
        ]
      end,
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_collection(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Collection,
      :create,
      authorize?: false,
      uses: %{
        seq: sequence(:dev_collection_seq, & &1),
        status: StreamData.member_of([:active, :draft]),
        featured: StreamData.boolean(),
        display_order: StreamData.integer(0..100)
      },
      defaults: fn %{
                     seq: seq,
                     status: status,
                     featured: featured,
                     display_order: display_order
                   } ->
        topic = Enum.at(@collection_names, rem(seq, length(@collection_names)))

        [
          name: "#{topic} #{div(seq, length(@collection_names)) + 1}",
          slug: "#{to_slug(topic)}-#{seq}",
          description: "A curated collection of #{topic} articles and tutorials.",
          status: status,
          schema: [],
          seo_tags: [],
          permissions: [],
          featured: featured,
          display_order: display_order,
          language: "en",
          language_group_id: nil,
          parent_collection_id: nil,
          site_id: nil
        ]
      end,
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_blogger(opts \\ [], tenant \\ nil) do
    first_names = [
      "Alice",
      "Bob",
      "Carol",
      "Dave",
      "Eve",
      "Frank",
      "Grace",
      "Henry",
      "Iris",
      "Jack"
    ]

    last_names = [
      "Smith",
      "Johnson",
      "Williams",
      "Brown",
      "Jones",
      "Garcia",
      "Miller",
      "Davis",
      "Wilson",
      "Moore"
    ]

    changeset_generator(
      MishkaBlog.Blogger,
      :create,
      authorize?: false,
      uses: %{
        seq: sequence(:dev_blogger_seq, & &1),
        expertise_areas: StreamData.repeatedly(fn -> Enum.take_random(@tag_names, 3) end),
        can_publish_directly: StreamData.boolean()
      },
      defaults: fn %{
                     seq: seq,
                     expertise_areas: expertise_areas,
                     can_publish_directly: can_publish_directly
                   } ->
        first = Enum.at(first_names, rem(seq, length(first_names)))
        last = Enum.at(last_names, rem(seq, length(last_names)))
        [main_area | _] = expertise_areas

        [
          user_id: nil,
          display_name: "#{first} #{last}",
          slug: "#{String.downcase(first)}-#{String.downcase(last)}-#{seq}",
          bio:
            "Passionate #{main_area} developer with years of experience building scalable systems.",
          avatar_url: nil,
          cover_image_url: nil,
          expertise_areas: expertise_areas,
          social_links: [],
          contact_email: nil,
          can_publish_directly: can_publish_directly,
          site_id: nil
        ]
      end,
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_team(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Team,
      :create,
      authorize?: false,
      uses: %{
        seq: sequence(:dev_team_seq, & &1),
        status: StreamData.member_of([:active, :active, :active, :inactive, :draft])
      },
      defaults: fn %{seq: seq, status: status} ->
        topic = Enum.at(@team_names, rem(seq, length(@team_names)))
        focus = Enum.at(@team_focus, rem(seq, length(@team_focus)))

        [
          name: "#{topic} #{div(seq, length(@team_names)) + 1}",
          slug: "#{to_slug(topic)}-#{seq}",
          description: "A dedicated team focused on #{focus}.",
          avatar_url: nil,
          cover_image_url: nil,
          status: status,
          site_id: nil
        ]
      end,
      overrides: opts,
      tenant: tenant
    )
  end

  def dev_tag(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Tag,
      :create,
      authorize?: false,
      uses: %{seq: sequence(:dev_tag_seq, & &1)},
      defaults: fn %{seq: seq} ->
        name = Enum.at(@tag_names, rem(seq, length(@tag_names)))

        [
          name: name,
          slug: "#{name}-#{seq}",
          description: "Articles and tutorials about #{name} development and best practices.",
          seo_tags: [],
          permissions: [],
          language: "en",
          language_group_id: nil,
          parent_tag_id: nil,
          site_id: nil
        ]
      end,
      overrides: opts,
      tenant: tenant
    )
  end

  @doc """
  A realistic comment. Moderation status is weighted the way a live queue looks — mostly approved with
  a thin tail of pending, spam and flagged rows — and pinning stays rare so the pinned marker keeps its
  meaning.
  """
  def dev_comment(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.Comment,
      :create,
      authorize?: false,
      tenant: tenant,
      defaults: [
        post_id: nil,
        author_id: nil,
        parent_comment_id: nil,
        content: StreamData.member_of(@comment_templates),
        status:
          StreamData.frequency([
            {70, StreamData.constant(:approved)},
            {15, StreamData.constant(:pending)},
            {8, StreamData.constant(:spam)},
            {7, StreamData.constant(:flagged)}
          ]),
        sender_data: StreamData.repeatedly(&sender_data/0),
        is_pinned:
          StreamData.frequency([
            {97, StreamData.constant(false)},
            {3, StreamData.constant(true)}
          ])
      ],
      overrides: opts
    )
  end

  def dev_auto_posting(opts \\ [], tenant \\ nil) do
    changeset_generator(
      MishkaBlog.AutoPosting,
      :create,
      authorize?: false,
      uses: %{
        seq: sequence(:dev_auto_posting_seq, & &1),
        is_active: StreamData.boolean()
      },
      defaults: fn %{seq: seq, is_active: is_active} ->
        plugin = Enum.at(@auto_posting_plugins, rem(seq, length(@auto_posting_plugins)))

        [
          name: "#{String.capitalize(plugin)} Auto Posting #{seq}",
          plugin: plugin,
          description: "Automatically share new posts to #{String.capitalize(plugin)}",
          is_active: is_active,
          config: %{"schedule" => "daily", "max_posts" => 5},
          site_id: nil
        ]
      end,
      overrides: opts,
      tenant: tenant
    )
  end

  @doc """
  A plausible browser user agent, used by the seeds when writing post-view rows.
  """
  def user_agent, do: Enum.random(@user_agents)

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp post_lifecycle_dates(:published) do
    {DateTime.utc_now()
     |> DateTime.add(-:rand.uniform(540) * 86_400, :second)
     |> DateTime.truncate(:second), nil}
  end

  defp post_lifecycle_dates(:draft), do: {nil, nil}

  defp post_lifecycle_dates(:scheduled) do
    {nil,
     DateTime.utc_now()
     |> DateTime.add((30 + :rand.uniform(15)) * 86_400, :second)
     |> DateTime.truncate(:second)}
  end

  defp post_content(topic, paragraphs) do
    Enum.map_join(1..paragraphs, "\n\n", fn p ->
      "<p>#{topic} — paragraph #{p}. This covers important aspects of the topic with practical examples and real-world applications.</p>"
    end)
  end

  defp post_seo_tags(title) do
    [
      %{
        "tag" => "meta",
        "attrs" => %{"name" => "description", "content" => "#{title} — comprehensive guide"},
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{"property" => "og:title", "content" => title},
        "content" => nil
      },
      %{
        "tag" => "meta",
        "attrs" => %{"name" => "twitter:card", "content" => "summary_large_image"},
        "content" => nil
      }
    ]
  end

  defp sender_data do
    %{
      "ip_address" =>
        "#{:rand.uniform(223)}.#{:rand.uniform(254)}.#{:rand.uniform(254)}.#{:rand.uniform(254)}",
      "user_agent" => user_agent()
    }
  end

  defp to_slug(value) do
    value |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
  end
end
