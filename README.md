<div align="center">

[![Buy Me a Coffee](https://img.shields.io/badge/Buy_Me_a_Coffee-mishkagroup-ffdd00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://www.buymeacoffee.com/mishkagroup)
[![GitHub Sponsors](https://img.shields.io/badge/GitHub_Sponsors-mishka--group-ea4aaa?style=flat-square&logo=github)](https://github.com/sponsors/mishka-group)

# Mishka Blog

**A multi-author [blog engine for Mishka CMS](https://mishka.tools/cms/extensions/blog), built with Elixir and Phoenix LiveView.**

[Website](https://mishka.tools/cms/extensions/blog) · [Documentation](https://mishka.tools/cms/extensions/blog/docs) · [Mishka CMS](https://mishka.tools/cms) · [Hire us](https://mishka.tools/hire-us)

</div>

## 📖 What is Mishka Blog?

`mishka_blog` is the blog extension of Mishka CMS. It adds posts, collections, tags, bloggers, editorial teams, threaded comments, ratings, bookmarks and follows to a site, with admin screens under `/admin/dashboard/blog`, a JSON:API, and ready-made page components that read the blog and draw it.

Every record belongs to a site, so each site in a Mishka CMS install has its own blog.

## 🧩 Part of Mishka CMS

Mishka Blog is an extension of [Mishka CMS](https://mishka.tools/cms), an open source real-time CMS. It runs on [mishka_cms_core](https://github.com/mishka-group/mishka_cms_core), the engine, inside the [mishka_cms](https://github.com/mishka-group/mishka_cms) application, and it is listed with the other [CMS extensions](https://mishka.tools/cms#extensions).

## ✨ Features

- Posts that are a draft, scheduled, published or archived, with a scheduled publish time, an excerpt, a featured flag and image, reading time, SEO tags and Schema.org data. A post's text can place components from the site's library, and its code blocks are highlighted when the post is saved.
- Collections for nested categories, and nested tags. Posts, collections and tags can be written in several languages.
- Version history with restore for posts, collections, tags, bloggers and teams.
- Bloggers with a public profile (bio, expertise, social links and a slug). A post can have several authors. Bloggers can be grouped into teams, and each team has its own page.
- Threaded comments with the moderation states pending, approved, flagged and spam, pinning, and up and down votes.
- For readers: a 1 to 5 star rating for each post, bookmarks, follows for bloggers and teams, and a count of unique views.
- An analytics page with daily views, the most-read posts, where readers came from and whether they were signed in, over a period you choose.
- Seventeen page components (eleven blocks that run their own queries and six smaller pieces they draw with) and nine sample pages: the blog index, a post, a category, a tag, an author, a team, and the lists of categories, tags and people.
- The sample pages hang on the site's `site-main` layout and draw nothing around themselves. The blog hands the layout its bar (Posts, Categories, Tags and People) and, for a post, a category, a tag, a blogger or a team, the languages that record is written in, each at its own address, which the header's language menu lists.
- SEO for each record: its own head, `BlogPosting` and breadcrumb JSON-LD, `sitemap.xml` entries for posts, categories, bloggers and teams, and share cards.
- A notification to the blog's admins when a post is published, and dashboard widgets for recent posts, top posts, drafts and scheduled posts, comments to moderate, and bloggers.
- A JSON:API for admins at `/api/json/v1/master/admin/mishka-blog/…` and `/api/json/v1/tenant/admin/mishka-blog/…`, and one for readers at `/api/json/v1/user/mishka-blog/…` (published posts, comments, ratings, bookmarks, follows and votes), described in the CMS's OpenAPI spec.
- Permissions `admin:dashboard:blog:post` and `admin:dashboard:blog:comment`, with `admin:api:` twins for the API, so a moderator can hold the comments alone.
- Events for plugins, such as `blog:blog_post:after_publish` and `blog:comment:after_create`.

## 🚀 Getting started

Mishka Blog is installed with [Mishka CMS](https://github.com/mishka-group/mishka_cms#-getting-started). The package is not on Hex. Mishka CMS loads it from `__extensions/mishka_blog` when that folder exists, and otherwise from GitHub at the revision pinned in `mix.lock`:

```elixir
{:mishka_blog, github: "mishka-group/mishka_blog", branch: "master", override: true}
```

Mishka CMS registers it in three places: `MishkaBlog` in `ash_domains` and `MishkaBlogWeb` in the core's `extensions` list, both in `config/config.exs`, and `MishkaBlog` in the domains of the JSON:API router.

Then install the blog onto a site. Tick Blog in the install wizard, or open the Blog dashboard of a site that does not have it yet and press Set up. Either way the site gets the seventeen components, the nine sample pages and a sidebar snippet. Running it again adds only what is missing and leaves anything you edited. On a site set up by an earlier release, the same run gives the new design to the sample pages and components nobody edited, and says which in its report.

For sample bloggers, posts and comments in development, run `mix run priv/repo/dev_seeds.exs` in `mishka_cms`.

## 📚 Documentation

- [Mishka Blog documentation](https://mishka.tools/cms/extensions/blog/docs), which is still being written
- [Features](https://mishka.tools/cms/extensions/blog#features), the [post editor](https://mishka.tools/cms/extensions/blog#editor), [SEO](https://mishka.tools/cms/extensions/blog#seo), the [REST API](https://mishka.tools/cms/extensions/blog#integrations) and the [admin preview](https://mishka.tools/cms/extensions/blog#demo)
- [Mishka CMS documentation](https://mishka.tools/cms/docs)
- [Mishka Installer documentation](https://mishka.tools/installer/docs), for plugins and events
- The [Mishka blog](https://mishka.tools/blog)

## 💬 Community and support

- Report a bug or ask a question in [GitHub issues](https://github.com/mishka-group/mishka_blog/issues).
- Read about new releases on the [Mishka blog](https://mishka.tools/blog).
- For a custom blog feature, a migration from another CMS or priority support, [hire the Mishka team](https://mishka.tools/hire-us).

## 💖 Support the project

Mishka CMS and its extensions are free and open source. You can support their development through [GitHub Sponsors](https://github.com/sponsors/mishka-group) or [Buy Me a Coffee](https://www.buymeacoffee.com/mishkagroup).

## 📜 License

Apache License 2.0. See [LICENSE](LICENSE).
