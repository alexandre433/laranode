<?php

namespace App\Services\RedisMonitor;

/**
 * The only shell that ever runs against a Redis box. Both scripts are read-only: PULL reads the collector's
 * jsonl files, LIVE sends ONE command per instance: `INFO all`. RedisMonitorScriptsTest guards that.
 */
final class RemoteScripts
{
    /** Args: "<port>:<since-epoch>". Prints "#<port>" then the jsonl lines newer than <since>. */
    public const PULL = <<<'SH'
D=${RM_METRICS_DIR:-/var/lib/ds-metrics}
for a in "$@"; do
  p=${a%%:*}; s=${a##*:}
  echo "#$p"
  f=$D/$p.jsonl
  if [ -r "$f" ]; then awk -v s="$s" 'match($0,/"ts":[0-9]+/) && substr($0,RSTART+5,RLENGTH-5)+0 > s' "$f"; fi
done
exit 0

SH;

    /** Args: "<port>:<tls 0|1>". One INFO per instance, filtered to numbers (no keys, no values, no config). */
    public const LIVE = <<<'SH'
if [ -n "${RM_PASSFILE:-}" ] && [ -r "$RM_PASSFILE" ]; then REDISCLI_AUTH=$(cat "$RM_PASSFILE"); export REDISCLI_AUTH; fi
echo "#ts $(date +%s.%N)"
for a in "$@"; do
  p=${a%%:*}; t=${a##*:}
  tls=""; [ "$t" = 1 ] && tls="--tls --insecure"
  echo "#$p"
  # shellcheck disable=SC2086
  timeout 4 redis-cli -h 127.0.0.1 -p "$p" $tls ${RM_USER:+--user "$RM_USER"} INFO all 2>/dev/null | tr -d '\r' | grep -E '^(redis_version|uptime_in_seconds|instantaneous_ops_per_sec|total_commands_processed|keyspace_hits|keyspace_misses|used_memory|maxmemory|total_net_input_bytes|total_net_output_bytes|connected_clients|blocked_clients|evicted_keys|db[0-9]+|cmdstat_[^:]+):'
done
exit 0

SH;
}
