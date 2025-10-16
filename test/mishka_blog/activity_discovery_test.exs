defmodule MishkaBlog.ActivityDiscoveryTest do
  @moduledoc """
  The activity log finds THIS extension's resources.

  `MishkaCmsCore.Activity.Discovery` scans every configured domain at run time and names no extension,
  so the only place the claim "it reaches mishka_blog" can be tested is here, where mishka_blog is the thing being
  installed. The library's own `MishkaCmsCore.Activity.DiscoveryTest` covers the core resources and the
  scan's invariants; each extension asserts its own half.
  """
  use ExUnit.Case, async: true

  alias MishkaCmsCore.Activity.Discovery

  test "paper_trailed/0 discovers this extension's versioned resources" do
    assert MishkaBlog.BlogPost in Discovery.paper_trailed()
  end
end
