defmodule OpenUITUI.Memcached.ParserTest do
  use ExUnit.Case, async: true

  alias OpenUITUI.Memcached.Parser

  @sample_ascii """
  STAT pid 1426\r
  STAT uptime 1230401\r
  STAT version 1.6.45\r
  STAT threads 4\r
  STAT curr_connections 3\r
  STAT total_connections 2493\r
  STAT max_connections 1024\r
  STAT cmd_get 238269\r
  STAT cmd_set 22079\r
  STAT cmd_flush 256\r
  STAT get_hits 204941\r
  STAT get_misses 33328\r
  STAT bytes_read 124221194\r
  STAT bytes_written 1276549934\r
  STAT limit_maxbytes 134217728\r
  STAT bytes 20947675\r
  STAT curr_items 4435\r
  STAT total_items 22079\r
  STAT evictions 0\r
  END\r
  STAT 18:chunk_size 4504\r
  STAT 18:total_pages 15\r
  STAT 18:total_chunks 3495\r
  STAT 18:used_chunks 3350\r
  STAT 20:chunk_size 7064\r
  STAT 20:total_pages 5\r
  STAT 20:total_chunks 740\r
  STAT 20:used_chunks 672\r
  STAT 19:chunk_size 5632\r
  STAT 19:total_pages 3\r
  STAT 19:total_chunks 558\r
  STAT 19:used_chunks 227\r
  STAT 17:chunk_size 3600\r
  STAT 17:total_pages 9\r
  STAT 17:total_chunks 2619\r
  STAT 17:used_chunks 103\r
  END\r
  STAT items:18:number 3350\r
  STAT items:18:evicted 0\r
  STAT items:20:number 672\r
  STAT items:20:evicted 0\r
  STAT items:19:number 227\r
  STAT items:19:evicted 0\r
  STAT items:17:number 103\r
  STAT items:17:evicted 0\r
  END\r
  """

  test "parse/1 parses raw Memcached ASCII output into the 5 structured sections" do
    report = Parser.parse(@sample_ascii)

    # 1. Service & Uptime
    assert report.service.pid == 1426
    assert report.service.version == "1.6.45"
    assert report.service.uptime_seconds == 1_230_401
    assert report.service.uptime_human == "~14d 5h"
    assert report.service.threads == 4

    # 2. Cache Performance & Hit Rate
    assert report.cache.hit_ratio_pct == 86.01
    assert report.cache.cmd_get == 238_269
    assert report.cache.get_hits == 204_941
    assert report.cache.get_misses == 33_328
    assert report.cache.cmd_set == 22_079
    assert report.cache.cmd_flush == 256

    # 3. Memory & Storage Health
    assert report.memory.bytes_used == 20_947_675
    assert report.memory.memory_used_human == "19.98 MB"
    assert report.memory.limit_maxbytes == 134_217_728
    assert report.memory.memory_limit_human == "128.0 MB"
    assert report.memory.utilization_pct == 15.61
    assert report.memory.curr_items == 4435
    assert report.memory.total_items == 22_079
    assert report.memory.evictions == 0

    # 4. Connections & Traffic
    assert report.connections.curr_connections == 3
    assert report.connections.max_connections == 1024
    assert report.connections.total_connections == 2493
    assert report.connections.network_in_human == "118.47 MB"
    assert report.connections.network_out_human == "1.19 GB"

    # 5. Slab Class Distribution (sorted by active items descending)
    assert Enum.map(report.slabs, & &1.id) == ["18", "20", "19", "17"]
    assert hd(report.slabs).items == 3350
    assert hd(report.slabs).pages == 15

    # OpenUI $live_* bindings projection
    bindings = Parser.to_openui_bindings(report)
    assert bindings["$live_hit_ratio"] == "86.01%"
    assert bindings["$live_slab_ids"] == ["18", "20", "19", "17"]
    assert length(bindings["$live_ops_kv"]) == 6
  end
end
