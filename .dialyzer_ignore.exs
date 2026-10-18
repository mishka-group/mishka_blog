# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

# The four warnings below are false. `MishkaBlogWeb.SidebarMenu.permissions/1` works at runtime
# (test/mishka_blog_web/sidebar_menu_test.exs calls it). They come from core's
# `MishkaCmsCore.Sidebar.Item.t()`, a GuardedStruct whose type dialyzer reads wrongly. Each entry
# names the file and the exact warning text, so nothing else in this file or any other file is
# hidden.
[
  {"lib/mishka_blog_web/sidebar_menu.ex", "Invalid type specification for function items."},
  {"lib/mishka_blog_web/sidebar_menu.ex", "Invalid type specification for function permissions."},
  {"lib/mishka_blog_web/sidebar_menu.ex", "The function call permissions will not succeed."},
  {"lib/mishka_blog_web/sidebar_menu.ex", "Function permissions/1 has no local return."}
]
