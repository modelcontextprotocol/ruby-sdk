# frozen_string_literal: true

require "test_helper"
require_relative "../../examples/in_memory_event_store"

# The store the SDK offers as an example is the one the conformance server and the resumability tests run on,
# so its bounds and its ids are checked like library code.
class InMemoryEventStoreTest < ActiveSupport::TestCase
  test "assigns ordered ids within a stream and replays the events after a given one" do
    store = InMemoryEventStore.new
    priming = store.store_event("s", nil)
    first = store.store_event("s", "{\"n\":1}")
    second = store.store_event("s", "{\"n\":2}")
    store.store_event("t", "{\"n\":3}")

    assert_equal ["s", [[first, "{\"n\":1}"], [second, "{\"n\":2}"]]], store.events_after(priming)
    assert_equal ["s", [[second, "{\"n\":2}"]]], store.events_after(first)
    assert_equal ["s", []], store.events_after(second)
    assert_equal 3, [priming, first, second].uniq.size
  end

  test "leaves priming events out of a replay" do
    store = InMemoryEventStore.new
    first = store.store_event("s", "{\"n\":1}")
    store.store_event("s", nil)
    second = store.store_event("s", "{\"n\":2}")

    assert_equal ["s", [[second, "{\"n\":2}"]]], store.events_after(first)
  end

  test "does not know an id it never assigned" do
    store = InMemoryEventStore.new
    store.store_event("s", "{}")

    assert_nil store.events_after("s/99")
    assert_nil store.events_after("other/1")
    assert_nil store.events_after("no-separator")
    assert_nil store.events_after(nil)
  end

  test "keeps at most max_events_per_stream events of a stream, dropping the oldest" do
    store = InMemoryEventStore.new(max_events_per_stream: 2)
    first = store.store_event("s", "a")
    second = store.store_event("s", "b")
    third = store.store_event("s", "c")

    assert_nil store.events_after(first), "a dropped event is no longer a cursor"
    assert_equal ["s", [[third, "c"]]], store.events_after(second)
  end

  test "keeps at most max_streams streams, dropping the one written to least recently" do
    store = InMemoryEventStore.new(max_streams: 2)
    a = store.store_event("a", "1")
    b = store.store_event("b", "2")
    a_again = store.store_event("a", "3")
    c = store.store_event("c", "4")

    assert_nil store.events_after(b)
    assert_equal ["a", [[a_again, "3"]]], store.events_after(a)
    assert_equal ["c", []], store.events_after(c)
  end

  test "keeps the retained messages under max_bytes, dropping the streams written to least recently" do
    store = InMemoryEventStore.new(max_bytes: 10)
    a = store.store_event("a", "aaaa")
    b = store.store_event("b", "bbbb")
    c = store.store_event("c", "cccc")

    assert_nil store.events_after(a)
    assert_equal ["b", []], store.events_after(b)
    assert_equal ["c", []], store.events_after(c)
  end

  test "never drops the stream just written to, however large its message" do
    store = InMemoryEventStore.new(max_bytes: 4)
    big = store.store_event("a", "x" * 10)

    assert_equal ["a", []], store.events_after(big)
  end

  test "never reuses an id after a stream was dropped and written to again" do
    store = InMemoryEventStore.new(max_streams: 1)
    first = store.store_event("s", "1")
    store.store_event("t", "2")
    again = store.store_event("s", "3")

    refute_equal first, again
    assert_nil store.events_after(first), "an id of the dropped stream is not a cursor into the rewritten one"
    assert_equal ["s", []], store.events_after(again)
  end

  test "rejects bounds that are not positive Integers" do
    assert_raises(ArgumentError) { InMemoryEventStore.new(max_events_per_stream: 0) }
    assert_raises(ArgumentError) { InMemoryEventStore.new(max_streams: nil) }
    assert_raises(ArgumentError) { InMemoryEventStore.new(max_bytes: 1.5) }
  end
end
