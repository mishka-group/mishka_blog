# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.Dev.Seeds do
  @moduledoc """
  Dev and stress seeds for MishkaBlog resources.

  "Archived" is seeded exactly one way: `Ash.destroy!/2` through a resource's `:destroy` action, in
  the very last pass of a run. That writes the `archived_at` soft-delete timestamp AND force-sets
  `status: :archived` on `BlogPost` and `Collection`, the two resources whose status enum carries
  that value.

  Nothing else ever writes `status: :archived`. The status pool in `MishkaBlog.Dev.Generator` leaves
  it out, and the seeds no longer mark live rows with the label: only `archived_at` decides which tab
  a row appears in, so a labelled-but-live post reads to an admin as an archived post sitting in All
  Posts. Seeded data therefore satisfies **status `:archived` if and only if `archived_at` is set**,
  which `MishkaBlog.Dev.SeedsArchivalTest` pins.

  `Comment`, `Tag`, `Blogger`, `Team` and `AutoPosting` have no `:archived` status at all: for them
  the soft delete is the only archival concept, and their destroy actions leave the status untouched
  — an archived `:spam` comment keeps its `:spam` label.

  Receives foundation data from `MishkaCmsCore.Dev.Seeds.dev_seed/0`.
  """

  alias MishkaBlog.{BlogPost, Blogger, Collection, Tag}
  alias MishkaCmsCore.Dev.Seeds
  import MishkaBlog.Dev.Generator

  require Ash.Query

  @languages ["en", "fa", "ru", "ar", "fr"]

  @team_roles ["author", "editor", "reviewer", "lead", "copy editor"]

  @rating_spread [5, 5, 5, 4, 4, 4, 3, 2]

  # What the locked examples name, and what keeps the unlisted ones out of an index.
  @example_permission "admin:dashboard:blog:post"

  @unindexed [%{tag: "meta", attrs: %{"name" => "robots"}, content: "noindex, follow"}]

  @translated_titles %{
    "fa" => [
      "شروع با Elixir",
      "Phoenix LiveView عمیق",
      "Ash Framework در تولید",
      "ساخت برنامه‌های بلادرنگ",
      "الگوهای سیستم‌های توزیع‌شده",
      "درختان نظارت OTP",
      "بهترین شیوه‌های GenServer",
      "بهینه‌سازی کوئری Ecto",
      "استراتژی‌های تست در Elixir",
      "استقرار با Fly.io",
      "GraphQL با Absinthe",
      "تنظیم عملکرد PostgreSQL",
      "استریم‌های LiveView",
      "تطبیق الگو در Elixir",
      "متاپروگرمینگ در Elixir",
      "WebSockets در مقابل SSE",
      "کانتینرسازی اپ‌های Elixir",
      "مشاهده‌پذیری با Telemetry",
      "Event Sourcing با Ash",
      "معماری چندمستأجری"
    ],
    "ru" => [
      "Начало работы с Elixir",
      "Глубокое погружение в Phoenix LiveView",
      "Ash Framework в производстве",
      "Создание приложений реального времени",
      "Паттерны распределённых систем",
      "Деревья супервизоров OTP",
      "Лучшие практики GenServer",
      "Оптимизация запросов Ecto",
      "Стратегии тестирования в Elixir",
      "Развёртывание с Fly.io",
      "GraphQL с Absinthe",
      "Настройка производительности PostgreSQL",
      "Стримы LiveView",
      "Сопоставление с образцом в Elixir",
      "Метапрограммирование в Elixir",
      "WebSockets против SSE",
      "Контейнеризация Elixir",
      "Наблюдаемость с Telemetry",
      "Event Sourcing с Ash",
      "Мультиарендная архитектура"
    ],
    "ar" => [
      "البدء مع Elixir",
      "الغوص العميق في Phoenix LiveView",
      "Ash Framework في الإنتاج",
      "بناء تطبيقات في الوقت الفعلي",
      "أنماط الأنظمة الموزعة",
      "أشجار الإشراف OTP",
      "أفضل ممارسات GenServer",
      "تحسين استعلامات Ecto",
      "استراتيجيات الاختبار في Elixir",
      "النشر مع Fly.io",
      "GraphQL مع Absinthe",
      "ضبط أداء PostgreSQL",
      "تدفقات LiveView",
      "مطابقة الأنماط في Elixir",
      "البرمجة الفوقية في Elixir",
      "WebSockets مقابل SSE",
      "حاويات تطبيقات Elixir",
      "المراقبة مع Telemetry",
      "Event Sourcing مع Ash",
      "معمارية متعددة المستأجرين"
    ],
    "fr" => [
      "Démarrer avec Elixir",
      "Plongée dans Phoenix LiveView",
      "Ash Framework en production",
      "Construire des applications temps réel",
      "Patterns de systèmes distribués",
      "Arbres de supervision OTP",
      "Meilleures pratiques GenServer",
      "Optimisation des requêtes Ecto",
      "Stratégies de test en Elixir",
      "Déploiement avec Fly.io",
      "GraphQL avec Absinthe",
      "Performance PostgreSQL",
      "Streams LiveView",
      "Pattern matching en Elixir",
      "Métaprogrammation en Elixir",
      "WebSockets vs SSE",
      "Conteneurisation d'Elixir",
      "Observabilité avec Telemetry",
      "Event Sourcing avec Ash",
      "Architecture multi-locataire"
    ]
  }

  @translated_collections %{
    "fa" => [
      "شروع به کار",
      "معماری نرم‌افزار",
      "کارایی و بهینه‌سازی",
      "امنیت",
      "تست و آزمون",
      "استقرار و انتشار",
      "پایگاه داده",
      "ابزارهای توسعه",
      "بهترین شیوه‌ها",
      "آموزش‌های گام‌به‌گام",
      "مقیاس‌پذیری",
      "طراحی رابط کاربری"
    ],
    "ru" => [
      "Первые шаги",
      "Архитектура",
      "Производительность",
      "Безопасность",
      "Тестирование",
      "Развёртывание",
      "Базы данных",
      "Инструменты разработки",
      "Лучшие практики",
      "Пошаговые руководства",
      "Масштабируемость",
      "Пользовательские интерфейсы"
    ],
    "ar" => [
      "البداية",
      "بنية النظام",
      "الأداء",
      "الأمان",
      "الاختبار",
      "النشر والتوزيع",
      "قواعد البيانات",
      "أدوات التطوير",
      "أفضل الممارسات",
      "دروس تعليمية",
      "قابلية التوسع",
      "واجهات المستخدم"
    ],
    "fr" => [
      "Premiers pas",
      "Architecture",
      "Performance",
      "Sécurité",
      "Tests",
      "Déploiement",
      "Bases de données",
      "Outils de développement",
      "Bonnes pratiques",
      "Tutoriels pas à pas",
      "Montée en charge",
      "Interfaces utilisateur"
    ]
  }

  @translated_tags %{
    "fa" => [
      "برنامه‌نویسی",
      "توسعه وب",
      "تست نرم‌افزار",
      "امنیت",
      "کارایی",
      "پایگاه داده",
      "استقرار",
      "معماری",
      "آموزش",
      "ابزارها",
      "همزمانی",
      "متن‌باز"
    ],
    "ru" => [
      "Программирование",
      "Веб-разработка",
      "Тестирование",
      "Безопасность",
      "Производительность",
      "Базы данных",
      "Развёртывание",
      "Архитектура",
      "Обучение",
      "Инструменты",
      "Параллелизм",
      "Открытый код"
    ],
    "ar" => [
      "البرمجة",
      "تطوير الويب",
      "الاختبار",
      "الأمان",
      "الأداء",
      "قواعد البيانات",
      "النشر",
      "بنية النظام",
      "التعلّم",
      "الأدوات",
      "التزامن",
      "مفتوح المصدر"
    ],
    "fr" => [
      "Programmation",
      "Développement web",
      "Tests",
      "Sécurité",
      "Performance",
      "Bases de données",
      "Déploiement",
      "Architecture",
      "Apprentissage",
      "Outils",
      "Concurrence",
      "Open source"
    ]
  }

  @translated_paragraphs %{
    "fa" => [
      "در این نوشته گام‌به‌گام سراغ مفاهیم پایه می‌رویم و هر بخش را با یک مثال کوچک روشن می‌کنیم.",
      "سپس همان الگو را در یک پروژه واقعی به کار می‌بریم و تفاوت‌های عملی را بررسی می‌کنیم.",
      "در پایان نکته‌های کارایی و خطاهای رایج را مرور می‌کنیم تا در تولید غافلگیر نشوید."
    ],
    "ru" => [
      "В этой статье мы шаг за шагом разбираем базовые понятия и подкрепляем каждое небольшим примером.",
      "Затем применяем тот же приём в реальном проекте и смотрим, чем он отличается на практике.",
      "В конце обсуждаем производительность и типичные ошибки, чтобы продакшн не преподнёс сюрпризов."
    ],
    "ar" => [
      "في هذه المقالة نتناول المفاهيم الأساسية خطوة بخطوة، ونوضّح كل جزء بمثال صغير.",
      "ثم نطبّق النمط نفسه على مشروع حقيقي ونقارن الفروق العملية بين الحالتين.",
      "وفي الختام نراجع نقاط الأداء والأخطاء الشائعة حتى لا تفاجئك بيئة الإنتاج."
    ],
    "fr" => [
      "Cet article reprend les concepts de base pas à pas et illustre chaque étape par un exemple court.",
      "Nous appliquons ensuite le même schéma à un projet réel pour en mesurer les différences concrètes.",
      "Nous terminons par les points de performance et les erreurs fréquentes, pour éviter les surprises en production."
    ]
  }

  @doc """
  Creates realistic blog seed data for a single site: multilingual posts, threaded comments, views,
  engagement rows and, as the final pass, a soft-deleted minority that populates the admin's
  Archived tab.

  Per-site volumes are derived from a hash of `site_id`, so a run is reproducible while the three
  sites differ from one another. `users` should include both master and tenant users; users belonging
  to another site are filtered out before bloggers and comment authors are picked.

  RUN AGAIN ON A SITE THAT HAS A BLOG, this adds no generated row and answers `:already_seeded`.
  Every row it generates has no name to recognise it by afterwards, so what is either there or not
  is the blog itself, and a site that has one keeps exactly the posts, comments and ratings it has
  rather than being given a second set beside them. The locked and unlisted examples are recognised
  by their slugs, so a re-run writes only the ones the site is missing.
  """
  @spec dev_seed(String.t(), [struct()], (String.t() -> any())) :: map() | :already_seeded
  def dev_seed(site_id, users, progress \\ fn _ -> :ok end) do
    Seeds.announce("  ==> [MishkaBlog] Seeding site #{String.slice(site_id, 0, 8)}...")

    # THE BLOG'S OWN COMPONENTS, BEFORE ITS POSTS, so an author opening the builder straight after a
    # seed finds them in the palette with something to show. The blocks are `stateful: true` rows —
    # `Phoenix.LiveComponent`s — which is what lets a list hold a page number of its own and read in
    # the background; the function components they draw their rows with are not.
    #
    # OUTSIDE THE GUARD BELOW, because it is idempotent on its own terms: `Kit.install!/1` upserts by
    # component name, so a site that has them keeps their ids and their history and a site missing
    # one gets it. That is also what makes it worth running on a site whose posts are already there.
    progress.("Installing the blog's live components…")
    MishkaBlog.Kit.install!(site_id)

    # AND THE SAMPLE PAGES, here rather than only in the Oban job a site create enqueues: a dev seed
    # that left them to the queue seeded three sites whose blog had no page to read it on until a
    # worker happened to run. `ensure!/1` writes only what the site is missing, so a site that has
    # them keeps the ones it has.
    progress.("Writing the blog's sample pages…")
    MishkaBlog.Provision.ensure!(site_id)

    # THE EXTENSION'S OWN ROLES, now that installing it has created their names.
    Seeds.seed_role_accounts(site_id, [
      {"writer", ["admin:dashboard:blog:post"]},
      {"moderator", ["admin:dashboard:blog:comment"]}
    ])

    result =
      if seeded?(site_id) do
        Seeds.announce("  ==> [MishkaBlog] This site already has a blog — nothing added.")
        :already_seeded
      else
        seeded = seed_site(site_id, users, dev_counts(site_id), progress)

        Seeds.announce(
          "  ==> [MishkaBlog] Done. #{length(seeded.posts)} posts, #{seeded.archived.posts} archived."
        )

        seeded
      end

    # A LOCKED AND AN UNLISTED EXAMPLE OF EACH KIND, so every site has a record to try a page's
    # permissions and its robots meta on. The post "Members only: the release checklist", the
    # category "Members only" and the tag "Staff only" name `admin:dashboard:blog:post`: signed out,
    # their pages send you to sign in; `viewer@<site>.test` gets a 404; `writer@<site>.test`, which
    # holds that permission, opens them. The post "Kept out of search engines", the category "Ideas in
    # progress" and the tag "Unlisted" open for everyone, but their robots meta says `noindex`, so the
    # sitemap leaves them out — as it leaves out the locked three.
    #
    # AFTER THE GUARD, not beside the steps above it: a post written first would make `seeded?/1` call
    # an empty site seeded. Each row is written only while the site has none at its slug, archived
    # ones included, so a re-run adds what is missing and an example somebody edited stays as it is.
    progress.("Writing the locked and unlisted examples…")
    seed_access_examples(site_id)

    result
  end

  # ONE POST IS ENOUGH TO SAY THE SITE HAS A BLOG. Archived ones count as well, and have to: the last
  # pass of a run soft-deletes a minority of what it wrote, so a check that looked only at live rows
  # would call a fully seeded site unseeded the moment somebody archived the rest.
  defp seeded?(site_id) do
    Enum.any?([:read_any, :master_archived], fn action ->
      BlogPost
      |> Ash.Query.for_read(action, %{}, authorize?: false)
      |> Ash.Query.filter(site_id == ^site_id)
      |> Ash.exists?(authorize?: false)
    end)
  end

  @doc """
  Stress seed: the same building blocks as `dev_seed/3` — multilingual posts, views, engagement and
  the archival pass — at large volumes, so stress data exercises the code paths the admin renders.
  The `:posts` option is the total post count across all five languages.
  """
  def stress_seed(site_id, users, opts \\ []) do
    Seeds.announce("  ==> [MishkaBlog] Stress seeding site #{String.slice(site_id, 0, 8)}...")

    result = seed_site(site_id, users, stress_counts(opts), fn _ -> :ok end)

    Seeds.announce("  ==> [MishkaBlog] Stress seed done for site #{String.slice(site_id, 0, 8)}.")

    result
  end

  # ---------------------------------------------------------------------------
  # Site pipeline
  # ---------------------------------------------------------------------------

  defp dev_counts(site_id) do
    %{
      tags: :erlang.phash2({site_id, :tags}, 17) + 12,
      collections: :erlang.phash2({site_id, :collections}, 6) + 4,
      bloggers: :erlang.phash2({site_id, :bloggers}, 5) + 4,
      teams: :erlang.phash2({site_id, :teams}, 2) + 3,
      posts: :erlang.phash2({site_id, :posts}, 23) + 18,
      comments: :erlang.phash2({site_id, :comments}, 101) + 60,
      auto_postings: :erlang.phash2({site_id, :auto_postings}, 2) + 3
    }
  end

  defp stress_counts(opts) do
    %{
      tags: Keyword.get(opts, :tags, 100),
      collections: Keyword.get(opts, :collections, 20),
      bloggers: Keyword.get(opts, :bloggers, 10),
      teams: Keyword.get(opts, :teams, 5),
      posts: max(div(Keyword.get(opts, :posts, 500), length(@languages)), 1),
      comments: Keyword.get(opts, :comments, 1000),
      auto_postings: Keyword.get(opts, :auto_postings, 5)
    }
  end

  # THE PICTURES ARE THE SITE'S OWN, read once and handed to whoever writes a row that carries one.
  # A cover, an avatar and a team banner used to be either `nil` or a path into the host
  # application's `priv/static`, which this project does not have — so a seeded blog showed broken
  # pictures wherever it showed any. `MishkaCmsCore.Dev.SeedMedia` puts real files in the library
  # before the extensions seed, and a site that has none answers `%{}`: every caller below treats a
  # missing shape as "no picture", which is also what a fresh install looks like.
  defp seed_site(site_id, users, counts, progress) do
    site_users = site_users(users, site_id)
    images = MishkaCmsCore.Dev.SeedMedia.images(site_id)

    progress.("Tags & translations")
    tag_groups = seed_tags(site_id, counts.tags)
    progress.("Collections")
    collection_groups = seed_collections(site_id, counts.collections)
    progress.("Bloggers & teams")
    bloggers = seed_bloggers(site_id, site_users, counts.bloggers, images)
    teams = seed_teams(site_id, counts.teams, images)
    members = seed_team_members(teams, bloggers)

    progress.("Posts (multilingual)")

    posts =
      seed_multilang_posts(
        site_id,
        bloggers,
        by_language(tag_groups),
        by_language(collection_groups),
        counts.posts,
        covers(images)
      )

    progress.("Comments")
    comments = seed_comments(site_id, posts, site_users, counts.comments)
    progress.("Auto-postings")
    auto_postings = seed_auto_postings(site_id, counts.auto_postings)

    progress.("Lifecycle transitions")
    posts = run_post_lifecycle(site_id, posts)
    comments = run_comment_lifecycle(site_id, comments)

    plan =
      archive_plan(site_id, %{
        posts: posts,
        comments: comments,
        tag_groups: tag_groups,
        collection_groups: collection_groups,
        bloggers: bloggers,
        teams: teams,
        auto_postings: auto_postings
      })

    progress.("Post views")
    seed_post_views(site_id, posts, site_users, plan.post_ids)

    progress.("Ratings, bookmarks, votes & followers")

    seed_engagement(
      %{posts: posts, comments: comments, bloggers: bloggers, teams: teams},
      site_users,
      plan
    )

    progress.("Backdating timestamps")
    backdate(site_id, %{posts: posts, comments: comments, teams: teams, members: members})

    progress.("Archiving (soft delete)")
    archived = archive_pass(site_id, plan)

    %{
      tags: Enum.map(tag_groups, & &1.master),
      collections: Enum.map(collection_groups, & &1.master),
      bloggers: bloggers,
      teams: teams,
      posts: posts,
      comments: comments,
      auto_postings: auto_postings,
      archived: archived
    }
  end

  @doc """
  Keeps only the users that may legitimately author content on this site: master users (`site_id` nil)
  and tenant users of this very site.

  `MishkaCmsCore.Dev.Seeds` hands every site the same "master" list, and that list contains
  `none@example.com`, which is created as a tenant user of the localhost site. Without this filter a
  blogger or comment author on one site can be another site's user.
  """
  def site_users(users, site_id) do
    Enum.filter(users, &(is_nil(&1.site_id) or &1.site_id == site_id))
  end

  # ---------------------------------------------------------------------------
  # Taxonomy
  # ---------------------------------------------------------------------------

  defp seed_tags(_site_id, count) when count < 1, do: []

  defp seed_tags(site_id, count) do
    {groups, _roots} =
      Enum.reduce(0..(count - 1), {[], []}, fn idx, {groups, roots} ->
        parent = nested_parent(roots, site_id, idx, :tag)
        master = dev_tag([parent_tag_id: parent], site_id) |> Ash.Generator.generate()
        group = %{master: master, translations: seed_tag_translations(site_id, master, idx)}
        {[group | groups], root_pool(roots, parent, master)}
      end)

    Enum.reverse(groups)
  end

  defp seed_tag_translations(site_id, master, idx) do
    Map.new(tl(@languages), fn lang ->
      names = Map.fetch!(@translated_tags, lang)

      record =
        tag(
          [
            name: Enum.at(names, rem(idx, length(names))),
            slug: "#{master.slug}-#{lang}",
            description: tag_description(lang),
            language: lang,
            language_group_id: master.id
          ],
          site_id
        )
        |> Ash.Generator.generate()

      {lang, record}
    end)
  end

  defp seed_collections(_site_id, count) when count < 1, do: []

  defp seed_collections(site_id, count) do
    {groups, _roots} =
      Enum.reduce(0..(count - 1), {[], []}, fn idx, {groups, roots} ->
        parent = nested_parent(roots, site_id, idx, :collection)

        master =
          dev_collection([parent_collection_id: parent], site_id) |> Ash.Generator.generate()

        group = %{
          master: master,
          translations: seed_collection_translations(site_id, master, idx)
        }

        {[group | groups], root_pool(roots, parent, master)}
      end)

    Enum.reverse(groups)
  end

  defp seed_collection_translations(site_id, master, idx) do
    Map.new(tl(@languages), fn lang ->
      names = Map.fetch!(@translated_collections, lang)

      record =
        collection(
          [
            name: Enum.at(names, rem(idx, length(names))),
            slug: "#{master.slug}-#{lang}",
            description: collection_description(lang),
            status: master.status,
            schema: [],
            seo_tags: [],
            featured: master.featured,
            display_order: master.display_order,
            language: lang,
            language_group_id: master.id
          ],
          site_id
        )
        |> Ash.Generator.generate()

      {lang, record}
    end)
  end

  defp nested_parent([], _site_id, _idx, _key), do: nil

  defp nested_parent(roots, site_id, idx, key) do
    case :erlang.phash2({site_id, idx, key, :nested}, 10) do
      draw when draw < 3 ->
        Enum.at(roots, rem(:erlang.phash2({site_id, idx, key}), length(roots))).id

      _draw ->
        nil
    end
  end

  defp root_pool(roots, nil, record), do: roots ++ [record]
  defp root_pool(roots, _parent, _record), do: roots

  defp by_language(groups) do
    Enum.reduce(groups, %{}, fn group, acc ->
      group.translations
      |> Map.put(group.master.language, group.master)
      |> Enum.reduce(acc, fn {lang, record}, inner ->
        Map.update(inner, lang, [record], &[record | &1])
      end)
    end)
  end

  defp language_pool(index, language), do: Map.get(index, language) || Map.get(index, "en") || []

  # ---------------------------------------------------------------------------
  # People
  # ---------------------------------------------------------------------------

  defp seed_bloggers(site_id, users, count, images) do
    users
    |> Enum.sort_by(&:erlang.phash2({site_id, &1.id, :blogger}))
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.map(fn {user, index} ->
      [
        user_id: user.id,
        avatar_url: pick(images, :avatar, index),
        cover_image_url: pick(images, :cover, index)
      ]
      |> dev_blogger(site_id)
      |> Ash.Generator.generate()
    end)
  end

  defp seed_teams(_site_id, count, _images) when count < 1, do: []

  defp seed_teams(site_id, count, images) do
    Enum.map(1..count, fn i ->
      [avatar_url: pick(images, :avatar, i), cover_image_url: pick(images, :cover, i)]
      |> dev_team(site_id)
      |> Ash.Generator.generate()
    end)
  end

  # The one at `index`, wrapping round, or `nil` when the site has no picture of that shape.
  defp pick(images, shape, index) do
    case Map.get(images, shape, []) do
      [] -> nil
      paths -> Enum.at(paths, rem(index, length(paths)))
    end
  end

  defp seed_team_members(_teams, []), do: []

  defp seed_team_members(teams, bloggers) do
    Enum.flat_map(teams, fn team ->
      count = min(:erlang.phash2({team.id, :members}, 6) + 2, length(bloggers))

      bloggers
      |> Enum.sort_by(&:erlang.phash2({team.id, &1.id, :member}))
      |> Enum.take(count)
      |> Enum.map(fn blogger ->
        [team_id: team.id, blogger_id: blogger.id, role: team_role(team, blogger)]
        |> team_member()
        |> Ash.Generator.generate()
      end)
    end)
  end

  defp team_role(team, blogger) do
    Enum.at(@team_roles, :erlang.phash2({team.id, blogger.id, :role}, length(@team_roles)))
  end

  # ---------------------------------------------------------------------------
  # Posts
  # ---------------------------------------------------------------------------

  # ONE EMPTY PER PICTURE, so half of the posts carry no cover however many covers the set ships.
  # Two `nil`s written in front of the pool said half and meant a quarter, and would have meant a
  # tenth the day somebody dropped more files into `priv/dev_seed_media`; counting the empties off
  # the pool is the only way the share survives that. They alternate rather than sitting in a block,
  # because a page of the list is what a developer looks at, not the whole table. A list, a card and
  # the admin table all have to look right for a post without a cover, and that is the common case
  # in any blog anybody actually writes.
  defp covers(images) do
    case Map.get(images, :cover, []) do
      [] -> [nil]
      pictures -> Enum.flat_map(pictures, &[nil, &1])
    end
  end

  defp seed_multilang_posts(_site_id, _bloggers, _tags, _collections, count, _covers)
       when count < 1,
       do: []

  defp seed_multilang_posts(site_id, bloggers, tag_index, collection_index, base_count, covers) do
    masters =
      Enum.map(0..(base_count - 1), fn idx ->
        post =
          [featured_image_url: Enum.at(covers, rem(idx, length(covers)))]
          |> dev_blog_post(site_id)
          |> Ash.Generator.generate()

        attach_relations(post, bloggers, tag_index, collection_index)
        {idx, post}
      end)

    translations =
      Enum.flat_map(masters, fn {idx, master} ->
        Enum.map(tl(@languages), fn lang ->
          post = create_translation_post(site_id, master, lang, idx)
          attach_relations(post, bloggers, tag_index, collection_index)
          post
        end)
      end)

    Enum.map(masters, &elem(&1, 1)) ++ translations
  end

  defp create_translation_post(site_id, master, lang, idx) do
    titles = Map.fetch!(@translated_titles, lang)
    title = Enum.at(titles, rem(idx, length(titles)))

    blog_post(
      [
        title: "#{title} — #{div(idx, length(titles)) + 1}",
        slug: "#{lang}-post-#{master.id}",
        content: translation_content(lang, title),
        excerpt: translation_excerpt(lang),
        featured_image_url: master.featured_image_url,
        featured: master.featured,
        status: master.status,
        published_at: master.published_at,
        scheduled_publish_at: master.scheduled_publish_at,
        language: lang,
        language_group_id: master.id,
        schema: [],
        seo_tags: []
      ],
      site_id
    )
    |> Ash.Generator.generate()
  end

  defp attach_relations(post, bloggers, tag_index, collection_index) do
    attach_bloggers(post, bloggers)
    attach_tags(post, language_pool(tag_index, post.language))
    attach_collections(post, language_pool(collection_index, post.language))
  end

  defp attach_bloggers(_post, []), do: :ok

  defp attach_bloggers(post, bloggers) do
    count = min(:erlang.phash2({post.id, :bloggers}, 3) + 1, length(bloggers))

    bloggers
    |> Enum.sort_by(&:erlang.phash2({post.id, &1.id, :blogger}))
    |> Enum.take(count)
    |> Enum.with_index()
    |> Enum.each(fn {blogger, index} ->
      [post_id: post.id, blogger_id: blogger.id, role: blogger_role(index)]
      |> post_blogger()
      |> Ash.Generator.generate()
    end)
  end

  defp blogger_role(0), do: "author"
  defp blogger_role(_index), do: "co-author"

  defp attach_tags(_post, []), do: :ok

  defp attach_tags(post, pool) do
    count = min(:erlang.phash2({post.id, :tags}, 6), length(pool))

    pool
    |> Enum.sort_by(&:erlang.phash2({post.id, &1.id, :tag}))
    |> Enum.take(count)
    |> Enum.each(fn record ->
      [post_id: post.id, tag_id: record.id] |> post_tag() |> Ash.Generator.generate()
    end)
  end

  defp attach_collections(_post, []), do: :ok

  defp attach_collections(post, pool) do
    count = min(:erlang.phash2({post.id, :collections}, 3), length(pool))

    pool
    |> Enum.sort_by(&:erlang.phash2({post.id, &1.id, :collection}))
    |> Enum.take(count)
    |> Enum.each(fn record ->
      [post_id: post.id, collection_id: record.id]
      |> post_collection()
      |> Ash.Generator.generate()
    end)
  end

  defp translation_content(lang, title) do
    body =
      @translated_paragraphs |> Map.fetch!(lang) |> Enum.map_join("\n\n", &"<p>#{&1}</p>")

    "<h2>#{title}</h2>\n\n" <> body
  end

  defp translation_excerpt(lang), do: @translated_paragraphs |> Map.fetch!(lang) |> hd()

  # ---------------------------------------------------------------------------
  # Comments
  # ---------------------------------------------------------------------------

  defp seed_comments(_site_id, [], _users, _count), do: []
  defp seed_comments(_site_id, _posts, _users, count) when count < 1, do: []

  defp seed_comments(site_id, posts, users, count) do
    {comments, _threads} =
      Enum.reduce(1..count, {[], %{}}, fn i, {acc, threads} ->
        post = Enum.at(posts, :erlang.phash2({site_id, i, :comment}, length(posts)))
        thread = Map.get(threads, post.id, [])
        parent = comment_parent(thread, i)

        comment =
          dev_comment(
            [
              post_id: post.id,
              author_id: comment_author_id(users, i),
              parent_comment_id: comment_id(parent)
            ],
            site_id
          )
          |> Ash.Generator.generate()

        {[comment | acc], Map.put(threads, post.id, [{comment, comment_depth(parent)} | thread])}
      end)

    Enum.reverse(comments)
  end

  defp comment_parent(_thread, i) when rem(i, 4) != 0, do: nil
  defp comment_parent([], _i), do: nil

  defp comment_parent(thread, i) do
    case Enum.filter(thread, fn {_comment, depth} -> depth < 2 end) do
      [] -> nil
      candidates -> Enum.at(candidates, rem(i, length(candidates)))
    end
  end

  defp comment_id(nil), do: nil
  defp comment_id({comment, _depth}), do: comment.id

  defp comment_depth(nil), do: 0
  defp comment_depth({_comment, depth}), do: depth + 1

  defp comment_author_id(_users, i) when rem(i, 7) == 0, do: nil
  defp comment_author_id([], _i), do: nil
  defp comment_author_id(users, i), do: Enum.at(users, rem(i, length(users))).id

  defp seed_auto_postings(_site_id, count) when count < 1, do: []

  defp seed_auto_postings(site_id, count) do
    Enum.map(1..min(count, 5), fn _i ->
      dev_auto_posting([], site_id) |> Ash.Generator.generate()
    end)
  end

  # ---------------------------------------------------------------------------
  # Lifecycle transitions (extra versions in the history)
  # ---------------------------------------------------------------------------

  defp run_post_lifecycle(site_id, posts), do: Enum.map(posts, &post_transition(site_id, &1))

  defp post_transition(site_id, %{status: :draft} = post),
    do: transition(site_id, post, :publish, 15)

  defp post_transition(site_id, %{status: :published} = post),
    do: transition(site_id, post, :unpublish, 8)

  defp post_transition(_site_id, post), do: post

  defp run_comment_lifecycle(site_id, comments),
    do: Enum.map(comments, &comment_transition(site_id, &1))

  defp comment_transition(site_id, %{status: :pending} = comment),
    do: transition(site_id, comment, :approve, 30)

  defp comment_transition(_site_id, comment), do: comment

  defp transition(site_id, record, action, pct) do
    case pick?(site_id, record, :lifecycle, pct) do
      true -> Ash.update!(record, %{}, action: action, tenant: site_id, authorize?: false)
      false -> record
    end
  end

  # ---------------------------------------------------------------------------
  # Views
  # ---------------------------------------------------------------------------

  defp seed_post_views(site_id, posts, users, skip_ids) do
    base = 180 + :erlang.phash2({site_id, :views}, 121)

    posts
    |> Enum.filter(&(&1.status == :published and !MapSet.member?(skip_ids, &1.id)))
    |> Enum.sort_by(&:erlang.phash2({site_id, &1.id, :rank}))
    |> Enum.with_index(1)
    |> Enum.each(fn {post, rank} -> seed_views_for_post(post, rank, base, users) end)
  end

  defp seed_views_for_post(post, rank, base, users) do
    total = max(round(base * :math.pow(rank, -0.9)), 1)
    viewers = view_users(post, users, total)
    net = :erlang.phash2({post.id, :net}, 200) + 11
    subnet = :erlang.phash2({post.id, :subnet}, 254) + 1
    window = view_window(post)
    span = max(DateTime.diff(DateTime.utc_now(), window), 1)

    0..(total - 1)
    |> Enum.map(fn i ->
      %{
        post_id: post.id,
        user_id: viewer_id(Enum.at(viewers, i)),
        ip_address: "#{net}.#{subnet}.#{div(i, 254)}.#{rem(i, 254) + 1}",
        user_agent: user_agent(),
        inserted_at: DateTime.add(window, :erlang.phash2({post.id, i, :seen}, span), :second)
      }
    end)
    |> then(&Ash.Seed.seed!(MishkaBlog.PostView, &1))
  end

  defp view_users(_post, [], _total), do: []

  defp view_users(post, users, total) do
    users
    |> Enum.sort_by(&:erlang.phash2({post.id, &1.id, :view}))
    |> Enum.take(min(round(total * 0.2), length(users)))
  end

  defp viewer_id(nil), do: nil
  defp viewer_id(user), do: user.id

  defp view_window(%{published_at: %DateTime{} = at}), do: at
  defp view_window(%{id: id}), do: past_datetime(id, :viewed, 180)

  # ---------------------------------------------------------------------------
  # Engagement
  # ---------------------------------------------------------------------------

  @doc """
  Fills the engagement tables the admin aggregates over — ratings, bookmarks, comment votes, blogger
  and team followers — so the star, bookmark and follower columns are not hard-zero.

  `MishkaBlog.TeamPermission` is not seeded: `dev_seed/3` receives only sites and users, and a team
  permission needs a `MishkaCmsCore.Accounts.Permission` record, which the core seed does not hand to
  the extension seeds.

  Archived posts and comments are skipped, so the aggregates the admin renders describe live rows.
  """
  def seed_engagement(
        %{posts: posts, comments: comments, bloggers: bloggers, teams: teams},
        users,
        plan
      ) do
    seed_post_ratings(posts, users, plan.post_ids)
    seed_post_bookmarks(posts, users, plan.post_ids)
    seed_comment_votes(comments, users, plan.comment_ids)
    seed_blogger_followers(bloggers, users)
    seed_team_followers(teams, users)
  end

  defp seed_post_ratings(posts, users, skip_ids) do
    posts
    |> live_published(skip_ids)
    |> Enum.each(fn post ->
      post
      |> engagement_users(users, :rating, 6)
      |> Enum.each(fn user ->
        [post_id: post.id, rating: rating_for(post, user)]
        |> post_rating(user)
        |> Ash.Generator.generate()
      end)
    end)
  end

  defp rating_for(post, user) do
    Enum.at(@rating_spread, :erlang.phash2({post.id, user.id, :rating}, length(@rating_spread)))
  end

  defp seed_post_bookmarks(posts, users, skip_ids) do
    posts
    |> live_published(skip_ids)
    |> Enum.each(fn post ->
      post
      |> engagement_users(users, :bookmark, 4)
      |> Enum.each(fn user ->
        [post_id: post.id] |> post_bookmark(user) |> Ash.Generator.generate()
      end)
    end)
  end

  defp seed_comment_votes(comments, users, skip_ids) do
    comments
    |> Enum.reject(&MapSet.member?(skip_ids, &1.id))
    |> Enum.each(fn comment ->
      comment
      |> engagement_users(users, :vote, 4)
      |> Enum.each(fn user ->
        [comment_id: comment.id, vote_type: vote_type(comment, user)]
        |> comment_vote(user)
        |> Ash.Generator.generate()
      end)
    end)
  end

  defp vote_type(comment, user) do
    case :erlang.phash2({comment.id, user.id, :vote}, 10) do
      draw when draw < 8 -> :up
      _draw -> :down
    end
  end

  defp seed_blogger_followers(bloggers, users) do
    Enum.each(bloggers, fn blogger ->
      blogger
      |> engagement_users(users, :follow, 5)
      |> Enum.each(fn user ->
        [blogger_id: blogger.id] |> blogger_follower(user) |> Ash.Generator.generate()
      end)
    end)
  end

  defp seed_team_followers(teams, users) do
    Enum.each(teams, fn team ->
      team
      |> engagement_users(users, :follow, 5)
      |> Enum.each(fn user ->
        [team_id: team.id] |> team_follower(user) |> Ash.Generator.generate()
      end)
    end)
  end

  defp live_published(posts, skip_ids) do
    Enum.filter(posts, &(&1.status == :published and !MapSet.member?(skip_ids, &1.id)))
  end

  defp engagement_users(_record, [], _key, _max), do: []

  defp engagement_users(record, users, key, max) do
    users
    |> Enum.sort_by(&:erlang.phash2({record.id, &1.id, key}))
    |> Enum.take(min(:erlang.phash2({record.id, key}, max), length(users)))
  end

  # ---------------------------------------------------------------------------
  # Backdating
  # ---------------------------------------------------------------------------

  @doc """
  Spreads creation timestamps over the last 18 months.

  `inserted_at` is a `create_timestamp` and appears in no `accept` list, so `Ash.Seed.update!/3` is the
  only Ash-native way to set it. That call goes straight to the data layer: no action, no validation,
  no notifier and no PaperTrail version, which is why a backdated row's `inserted_at` will not match
  the timestamp of its own first version. It also applies update defaults, so `updated_at` has to be
  passed explicitly or it silently resets to now.

  This pass must run before `archive_pass/2`: the `prevent_archived_*_updates` triggers raise on any
  update of a row that already has an `archived_at`.
  """
  def backdate(site_id, %{posts: posts, comments: comments, teams: teams, members: members}) do
    team_times = backdate_teams(site_id, teams)
    post_times = backdate_posts(site_id, posts)
    backdate_comments(site_id, comments, post_times)
    backdate_team_members(members, team_times)
  end

  defp backdate_teams(site_id, teams) do
    Map.new(teams, fn team ->
      at = past_datetime(team.id, :team, 540)
      Ash.Seed.update!(team, %{inserted_at: at, updated_at: at}, tenant: site_id)
      {team.id, at}
    end)
  end

  defp backdate_posts(site_id, posts) do
    Map.new(posts, fn post ->
      at = post_inserted_at(post)
      Ash.Seed.update!(post, %{inserted_at: at, updated_at: at}, tenant: site_id)
      {post.id, at}
    end)
  end

  defp post_inserted_at(%{status: :published, published_at: %DateTime{} = at}), do: at
  defp post_inserted_at(%{id: id}), do: past_datetime(id, :created, 540)

  defp backdate_comments(site_id, comments, post_times) do
    Enum.each(comments, fn comment ->
      at = between(Map.get(post_times, comment.post_id), comment.id, :commented)
      Ash.Seed.update!(comment, %{inserted_at: at, updated_at: at}, tenant: site_id)
    end)
  end

  defp backdate_team_members(members, team_times) do
    Enum.each(members, fn member ->
      at = between(Map.get(team_times, member.team_id), member.id, :joined)
      Ash.Seed.update!(member, %{joined_at: at})
    end)
  end

  defp between(nil, id, key), do: past_datetime(id, key, 180)

  defp between(%DateTime{} = base, id, key) do
    span = max(DateTime.diff(DateTime.utc_now(), base), 1)
    DateTime.add(base, :erlang.phash2({id, key}, span), :second)
  end

  defp past_datetime(id, key, days) do
    DateTime.add(DateTime.utc_now(), -:erlang.phash2({id, key}, days) * 86_400, :second)
  end

  # ---------------------------------------------------------------------------
  # Soft delete (always the last write to the generated rows)
  # ---------------------------------------------------------------------------

  @doc """
  Chooses the rows that will be soft-deleted, without touching the database.

  The slice is picked from a hash of `{site_id, record_id, :archive}` so the archived set is the same
  on every run, and it stays a genuine minority: a soft delete is a full Ash destroy that writes a
  PaperTrail version, emits an event and broadcasts over PubSub.

  Two rules shape the selection. Language masters are only archived together with their whole group,
  since a master with live translations is a state the app declares invalid. And post comments are
  archived alongside their post, because no resource declares `archive_related` — an orphan comment
  would render as "On: Unknown".
  """
  def archive_plan(site_id, %{posts: posts, comments: comments} = data) do
    post_targets = post_archive_targets(site_id, posts)
    post_ids = MapSet.new(post_targets, & &1.id)

    orphan_comments = Enum.filter(comments, &MapSet.member?(post_ids, &1.post_id))
    orphan_ids = MapSet.new(orphan_comments, & &1.id)

    moderation_comments =
      comments
      |> Enum.reject(&MapSet.member?(orphan_ids, &1.id))
      |> Enum.filter(&(&1.status in [:spam, :flagged] and pick?(site_id, &1, :archive, 60)))

    comment_targets = orphan_comments ++ moderation_comments
    collection_targets = translation_targets(data.collection_groups, site_id, 2)

    %{
      posts: post_targets,
      post_ids: post_ids,
      comments: comment_targets,
      comment_ids: MapSet.new(comment_targets, & &1.id),
      tags: translation_targets(data.tag_groups, site_id, 2),
      collections: collection_targets,
      collection_ids: MapSet.new(collection_targets, & &1.id),
      bloggers: pick_n(data.bloggers, site_id, :blogger, 1),
      teams: pick_n(data.teams, site_id, :team, 1),
      auto_postings: pick_n(data.auto_postings, site_id, :auto_posting, 1)
    }
  end

  defp post_archive_targets(site_id, posts) do
    group_ids =
      posts
      |> Enum.filter(&(&1.language == "en"))
      |> Enum.sort_by(&:erlang.phash2({site_id, &1.id, :archive}))
      |> Enum.take(2)
      |> MapSet.new(& &1.id)

    Enum.filter(posts, fn post ->
      MapSet.member?(group_ids, post.language_group_id) or
        (post.language != "en" and pick?(site_id, post, :archive, 6))
    end)
  end

  defp translation_targets(groups, site_id, count) do
    groups
    |> Enum.flat_map(&Map.values(&1.translations))
    |> pick_n(site_id, :translation, count)
  end

  defp pick_n(records, site_id, key, count) do
    records
    |> Enum.sort_by(&:erlang.phash2({site_id, &1.id, key, :archive}))
    |> Enum.take(count)
  end

  defp pick?(site_id, record, key, pct), do: :erlang.phash2({site_id, record.id, key}, 100) < pct

  @doc """
  Executes the plan, children before parents, and reads one row back through `:get_archived` to prove
  the rows really moved to the Archived tab.

  `Ash.destroy!/2` on these resources is a soft delete: `AshArchival` rewrites the `:destroy` action to
  set `archived_at` instead of removing the row. `:permanent_destroy` is the one that really deletes
  and is never used here. On `BlogPost` and `Collection` the destroy also force-sets `status:
  :archived`; on `Comment`, `Tag`, `Blogger` and `AutoPosting` the status is left alone, so an archived
  `:spam` comment keeps its moderation label.

  A team's `MishkaBlog.TeamMember` rows are left in place: that join resource has no archival, so
  destroying them would be a real delete and the membership could not come back with an unarchive.

  Nothing may write to a record after this pass — the `prevent_archived_*_updates` triggers raise on
  any update of an archived row.
  """
  def archive_pass(site_id, plan) do
    Enum.each(plan.comments, &archive(&1, site_id))

    {masters, translations} = Enum.split_with(plan.posts, &(&1.id == &1.language_group_id))
    Enum.each(translations, &archive(&1, site_id))
    Enum.each(masters, &archive(&1, site_id))

    Enum.each(plan.tags, &archive(&1, site_id))
    Enum.each(plan.collections, &archive(&1, site_id))
    Enum.each(plan.bloggers, &archive(&1, site_id))
    Enum.each(plan.teams, &archive(&1, site_id))
    Enum.each(plan.auto_postings, &archive(&1, site_id))

    verify_archived(site_id, plan.posts)

    %{
      posts: length(plan.posts),
      comments: length(plan.comments),
      tags: length(plan.tags),
      collections: length(plan.collections),
      bloggers: length(plan.bloggers),
      teams: length(plan.teams),
      auto_postings: length(plan.auto_postings)
    }
  end

  defp archive(record, site_id) do
    Ash.destroy!(record, action: :destroy, tenant: site_id, authorize?: false)
  end

  defp verify_archived(_site_id, []), do: :ok

  defp verify_archived(site_id, [post | _rest]) do
    Ash.get!(MishkaBlog.BlogPost, post.id,
      action: :get_archived,
      tenant: site_id,
      authorize?: false
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Locked and unlisted examples
  # ---------------------------------------------------------------------------

  # EACH ROW ON ITS OWN, by its slug, so a site missing one gets that one. A link is written only
  # beside a row written now: two rows that were both there keep whatever links they have.
  defp seed_access_examples(site_id) do
    author = site_author(site_id)

    {locked_post, new_locked_post?} =
      example(BlogPost, site_id, "members-only-release-checklist", fn ->
        example_post(site_id, author,
          title: "Members only: the release checklist",
          slug: "members-only-release-checklist",
          excerpt: "What has to be true before a release goes out — for members only.",
          content:
            "<p>Before a release goes out, four things have to be true: the changelog says what " <>
              "changed, the migrations have run against a copy of production, every feature " <>
              "flag is where the release notes say it is, and someone other than the author has " <>
              "read the diff. This post names a permission, so only an account holding it can " <>
              "open it.</p>",
          permissions: [@example_permission]
        )
      end)

    {unindexed_post, new_unindexed_post?} =
      example(BlogPost, site_id, "kept-out-of-search-engines", fn ->
        example_post(site_id, author,
          title: "Kept out of search engines",
          slug: "kept-out-of-search-engines",
          excerpt: "Open to every reader, but kept out of search results and the sitemap.",
          content:
            "<p>Anyone can read this post, and a link to it works for everyone. Its robots meta " <>
              "says noindex, though, so search engines are asked not to list it and the site's " <>
              "sitemap leaves it out — the way you keep a thank-you page or an old announcement " <>
              "out of search results without taking it down.</p>",
          seo_tags: @unindexed
        )
      end)

    {category, new_category?} =
      example(Collection, site_id, "members-only", fn ->
        [
          name: "Members only",
          slug: "members-only",
          description: "Posts only an account holding the blog's post permission can open.",
          status: :active,
          permissions: [@example_permission],
          language: "en"
        ]
        |> collection(site_id)
        |> Ash.Generator.generate()
      end)

    {unlisted, new_tag?} =
      example(Tag, site_id, "unlisted", fn ->
        [
          name: "Unlisted",
          slug: "unlisted",
          description:
            "Posts open to every reader but kept out of search results and the sitemap.",
          seo_tags: @unindexed,
          language: "en"
        ]
        |> tag(site_id)
        |> Ash.Generator.generate()
      end)

    {unindexed_category, new_unindexed_category?} =
      example(Collection, site_id, "ideas-in-progress", fn ->
        [
          name: "Ideas in progress",
          slug: "ideas-in-progress",
          description: "Open to every reader, but kept out of search results and the sitemap.",
          status: :active,
          seo_tags: @unindexed,
          language: "en"
        ]
        |> collection(site_id)
        |> Ash.Generator.generate()
      end)

    {locked_tag, new_locked_tag?} =
      example(Tag, site_id, "staff-only", fn ->
        [
          name: "Staff only",
          slug: "staff-only",
          description:
            "Only an account holding the blog's post permission can open this tag's page.",
          permissions: [@example_permission],
          language: "en"
        ]
        |> tag(site_id)
        |> Ash.Generator.generate()
      end)

    link(locked_post, category, new_locked_post? or new_category?, fn post, row ->
      post_collection(post_id: post.id, collection_id: row.id)
    end)

    link(unindexed_post, unlisted, new_unindexed_post? or new_tag?, fn post, row ->
      post_tag(post_id: post.id, tag_id: row.id)
    end)

    link(unindexed_post, unindexed_category, new_unindexed_post? or new_unindexed_category?, fn
      post, row -> post_collection(post_id: post.id, collection_id: row.id)
    end)

    link(locked_post, locked_tag, new_locked_post? or new_locked_tag?, fn post, row ->
      post_tag(post_id: post.id, tag_id: row.id)
    end)

    [
      new_locked_post?,
      new_unindexed_post?,
      new_category?,
      new_tag?,
      new_unindexed_category?,
      new_locked_tag?
      | seed_inherited_examples(site_id, author, category, new_category?)
    ]
    |> Enum.count(& &1)
    |> case do
      0 -> :ok
      count -> Seeds.announce("  ==> [MishkaBlog] Added #{count} locked or unlisted example(s).")
    end
  end

  # WHAT A POST TAKES FROM ITS CATEGORY: a post naming nothing filed under "Members only" opens with
  # that category's permission, as does a category under it and a post filed there; a post naming
  # its own opens with that one alone. Under an archived "Members only" there is nothing to file them
  # under, so none is written.
  defp seed_inherited_examples(_site_id, _author, nil, _new_category?), do: []

  defp seed_inherited_examples(site_id, author, members, new_members?) do
    {filed, new_filed?} =
      example(BlogPost, site_id, "filed-under-members-only", fn ->
        example_post(site_id, author,
          title: "Filed under Members only",
          slug: "filed-under-members-only",
          excerpt: "Names no permission of its own, so it takes its category's.",
          content:
            "<p>This post names no permission itself. It is filed under the Members only " <>
              "category, which does, so it opens only for an account holding that category's " <>
              "permission — and leaves the sitemap with it.</p>"
        )
      end)

    {guides, new_guides?} =
      example(Collection, site_id, "members-only-guides", fn ->
        [
          name: "Members only guides",
          slug: "members-only-guides",
          description:
            "Names no permission; it sits under Members only and takes its permission.",
          status: :active,
          parent_collection_id: members.id,
          language: "en"
        ]
        |> collection(site_id)
        |> Ash.Generator.generate()
      end)

    {guide, new_guide?} =
      example(BlogPost, site_id, "a-guide-for-members", fn ->
        example_post(site_id, author,
          title: "A guide for members",
          slug: "a-guide-for-members",
          excerpt: "Filed under a category inside Members only, so it is locked by it too.",
          content:
            "<p>Neither this post nor its category names a permission. Its category sits under " <>
              "Members only, which does, so both open only for an account holding it.</p>"
        )
      end)

    {own, new_own?} =
      example(BlogPost, site_id, "own-lock-wins", fn ->
        example_post(site_id, author,
          title: "Its own lock wins",
          slug: "own-lock-wins",
          excerpt: "Filed under Members only, but names its own permission, which wins.",
          content:
            "<p>This post is filed under Members only, yet names a permission of its own: the " <>
              "documentation's section permission. Its own wins, so an account holding only the " <>
              "category's permission cannot open it, and one holding this one can.</p>",
          permissions: ["admin:dashboard:document:section"]
        )
      end)

    file = fn post, row -> post_collection(post_id: post.id, collection_id: row.id) end
    link(filed, members, new_filed? or new_members?, file)
    link(guide, guides, new_guide? or new_guides?, file)
    link(own, members, new_own? or new_members?, file)

    [new_filed?, new_guides?, new_guide?, new_own?]
  end

  # The live row at `slug` and whether it was written now: the one there, else the one `create`
  # writes. An archived row holds its slug as well, so it counts as there and answers `nil` — nothing
  # is linked to a row in the archive.
  defp example(resource, site_id, slug, create) do
    case resource |> at_slug(:read, site_id, slug) |> Ash.read_one!(authorize?: false) do
      %{} = row -> {row, false}
      nil -> archived_or_new(resource, site_id, slug, create)
    end
  end

  defp archived_or_new(resource, site_id, slug, create) do
    if resource |> at_slug(:archived, site_id, slug) |> Ash.exists?(authorize?: false),
      do: {nil, false},
      else: {create.(), true}
  end

  defp at_slug(resource, action, site_id, slug) do
    resource
    |> Ash.Query.for_read(action, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.filter(slug == ^slug)
  end

  # A published English post, three days old, under the site's first blogger when it has one.
  defp example_post(site_id, author, attrs) do
    post =
      attrs
      |> Keyword.merge(
        status: :published,
        published_at:
          DateTime.utc_now() |> DateTime.add(-3 * 86_400) |> DateTime.truncate(:second),
        language: "en"
      )
      |> blog_post(site_id)
      |> Ash.Generator.generate()

    attach_bloggers(post, author)
    post
  end

  # The site's first blogger by slug, as a list of one; none on a site with no blogger yet.
  defp site_author(site_id) do
    Blogger
    |> Ash.Query.for_read(:read, %{}, tenant: site_id, authorize?: false)
    |> Ash.Query.sort(slug: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
  end

  defp link(%{} = post, %{} = row, true, generator),
    do: post |> generator.(row) |> Ash.Generator.generate()

  defp link(_post, _row, _new?, _generator), do: :ok

  # ---------------------------------------------------------------------------
  # Localized copy
  # ---------------------------------------------------------------------------

  defp collection_description("fa"), do: "مجموعه‌ای از نوشته‌های مرتبط در این دسته."
  defp collection_description("ru"), do: "Подборка связанных статей в этой категории."
  defp collection_description("ar"), do: "مجموعة من المقالات المرتبطة في هذه الفئة."
  defp collection_description("fr"), do: "Une sélection d'articles liés dans cette catégorie."
  defp collection_description(_), do: "A curated set of related posts in this category."

  defp tag_description("fa"), do: "برچسبی برای نوشته‌های مرتبط با این موضوع."
  defp tag_description("ru"), do: "Метка для статей по этой теме."
  defp tag_description("ar"), do: "وسم للمقالات المرتبطة بهذا الموضوع."
  defp tag_description("fr"), do: "Une étiquette pour les articles sur ce sujet."
  defp tag_description(_), do: "A label for posts about this topic."
end
