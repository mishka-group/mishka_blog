# SPDX-FileCopyrightText: 2026 Mishka Group contributors <https://github.com/mishka-group/mishka_blog/graphs/contributors>
#
# SPDX-License-Identifier: Apache-2.0

defmodule MishkaBlog.TestJsonApiRouter do
  @moduledoc """
  The JSON:API surface these tests call, assembled for this extension alone.

  `MishkaCmsCore.Accounts` is here beside `MishkaBlog` because a blog request has to be made by
  somebody: the suite signs a user in over `/auth/user/sign-in` and sends the token back on every
  later call, and those routes belong to the accounts domain. `MishkaCmsCore.Runtime` supplies the
  site a post is scoped to.

  The CMS's own `MishkaCmsWeb.AshJsonApiRouter` mounts every domain in the system; this one mounts the
  three the blog cannot be exercised without.
  """

  use AshJsonApi.Router,
    domains: [MishkaBlog, MishkaCmsCore.Accounts, MishkaCmsCore.Runtime],
    open_api: "/open_api"
end
