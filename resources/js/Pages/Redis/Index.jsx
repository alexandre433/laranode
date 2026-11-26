import AuthenticatedLayout from '@/Layouts/AuthenticatedLayout';
import { Head } from '@inertiajs/react';
import { useEffect, useMemo, useState } from 'react';
import { Line } from 'react-chartjs-2';
import {
    Chart as ChartJS,
    CategoryScale,
    LinearScale,
    PointElement,
    LineElement,
    Title,
    Tooltip,
    Legend,
    Filler,
} from 'chart.js';
import { TbServer2 } from 'react-icons/tb';
import { fmtBytes, fmtNum, fmtPct, fmtRate, fmtUptime, labelFor, memLevel } from './format';

ChartJS.register(CategoryScale, LinearScale, PointElement, LineElement, Title, Tooltip, Legend, Filler);

const WINDOWS = [
    ['live', 'Live'],
    ['1h', '1 h'],
    ['6h', '6 h'],
    ['1d', '1 day'],
    ['7d', '7 days'],
];

const PILL = {
    ok: 'bg-green-100 text-green-800 dark:bg-green-900 dark:text-green-200',
    amber: 'bg-amber-100 text-amber-800 dark:bg-amber-900 dark:text-amber-200',
    red: 'bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200',
    none: 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300',
};

const card = 'shadow-md rounded-lg bg-white dark:bg-gray-950 p-6 text-gray-700 dark:text-gray-300';

function Stat({ label, value, sub, testid }) {
    return (
        <div className="rounded-lg border border-gray-200 dark:border-gray-800 p-4" data-testid={testid}>
            <div className="text-xs uppercase tracking-wide text-gray-500 dark:text-gray-400">{label}</div>
            <div className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{value}</div>
            {sub && <div className="text-xs text-gray-500 dark:text-gray-400">{sub}</div>}
        </div>
    );
}

function Chart({ title, testid, series, windowName, lines, fmt, stacked }) {
    const data = {
        labels: series.map((s) => labelFor(s.t, windowName)),
        datasets: lines.map((l) => ({
            label: l.label,
            data: series.map((s) => (l.get(s) === undefined ? null : l.get(s))),
            borderColor: l.color,
            backgroundColor: l.color + '33',
            fill: !!l.fill,
            tension: 0.25,
            pointRadius: 0,
            borderWidth: 2,
            borderDash: l.dash,
            spanGaps: false,
        })),
    };
    const options = {
        responsive: true,
        maintainAspectRatio: false,
        animation: false,
        interaction: { mode: 'index', intersect: false },
        plugins: {
            legend: { display: lines.length > 1, labels: { color: '#9ca3af' } },
            tooltip: { callbacks: { label: (c) => `${c.dataset.label}: ${fmt(c.parsed.y)}` } },
        },
        scales: {
            x: { ticks: { color: '#9ca3af', maxTicksLimit: 8, maxRotation: 0 }, grid: { display: false } },
            y: { beginAtZero: true, stacked: !!stacked, ticks: { color: '#9ca3af', callback: (v) => fmt(v) }, grid: { color: '#9ca3af22' } },
        },
    };
    return (
        <div className="rounded-lg border border-gray-200 dark:border-gray-800 p-4">
            <div className="text-sm font-medium mb-2 text-gray-800 dark:text-gray-200">{title}</div>
            <div style={{ height: 180 }} data-testid={testid}>
                <Line data={data} options={options} />
            </div>
        </div>
    );
}

export default function RedisIndex({ enabled, instances, status: status0, alerts: alerts0 }) {
    const [port, setPort] = useState(instances[0]?.port);
    const [windowName, setWindowName] = useState('1d');
    const [payload, setPayload] = useState(null);
    const [error, setError] = useState(null);
    const [status, setStatus] = useState(status0);
    const [alerts, setAlerts] = useState(alerts0 || []);

    useEffect(() => {
        if (!enabled || port === undefined) return undefined;
        let stop = false;
        let timer;
        const load = async () => {
            try {
                const res = await fetch(`${route('redis.data')}?port=${port}&window=${windowName}`, { headers: { Accept: 'application/json' }, credentials: 'same-origin' });
                if (!res.ok) throw new Error(`HTTP ${res.status}`);
                const j = await res.json();
                if (stop) return;
                setPayload(j.data);
                setStatus(j.status);
                setAlerts(j.alerts || []);
                setError(null);
            } catch (e) {
                if (!stop) setError(String(e.message || e));
            }
            if (!stop) timer = setTimeout(load, windowName === 'live' ? 5000 : 60000);
        };
        setPayload(null);
        load();
        return () => {
            stop = true;
            clearTimeout(timer);
        };
    }, [enabled, port, windowName]);

    const s = payload?.summary;
    const level = memLevel(s?.memPct);
    const alertFor = (p) => alerts.find((a) => a.port === p);
    const secs = payload ? payload.bucket : 1;
    const perSec = (v) => (v === null || v === undefined ? null : v / secs);

    const lines = useMemo(
        () => ({
            ops: [{ label: 'ops/s', color: '#6366f1', fill: true, get: (x) => x.ops }],
            hits: [
                { label: 'Hits', color: '#22c55e', get: (x) => x.hits },
                { label: 'Misses', color: '#ef4444', get: (x) => x.miss },
            ],
            mem: [
                { label: 'Used', color: '#0ea5e9', fill: true, get: (x) => x.mem },
                { label: 'Max', color: '#f59e0b', dash: [6, 4], get: (x) => (x.max > 0 ? x.max : null) },
            ],
            net: [
                { label: 'In', color: '#14b8a6', get: (x) => perSec(x.rx) },
                { label: 'Out', color: '#a855f7', get: (x) => perSec(x.tx) },
            ],
            keys: [{ label: 'Keys', color: '#eab308', get: (x) => x.keys }],
            cli: [{ label: 'Clients', color: '#ec4899', get: (x) => x.cli }],
        }),
        [secs],
    );

    return (
        <AuthenticatedLayout
            header={
                <h2 className="font-semibold text-lg text-gray-800 dark:text-gray-200 leading-tight flex items-center">
                    <TbServer2 className="mr-2" />
                    Redis
                </h2>
            }
        >
            <Head title="Redis" />
            <div className="max-w-7xl mt-6 px-0 lg:px-4 space-y-6">
                {!enabled && (
                    <div className={card} data-testid="redis-disabled">
                        The Redis monitor is off. Set <code>REDIS_MONITOR_ENABLED=true</code> and the SSH settings in the panel <code>.env</code> (see docs/redis-monitor.md).
                    </div>
                )}

                {enabled && (
                    <>
                        {alerts.length > 0 && (
                            <div className="rounded-lg border border-red-300 bg-red-50 dark:bg-red-950 dark:border-red-800 p-4 text-red-800 dark:text-red-200" data-testid="redis-alerts">
                                {alerts.map((a) => (
                                    <div key={a.id}>
                                        Storage {a.threshold}%: {instances.find((i) => i.port === a.port)?.label || a.port} reached {a.pct.toFixed(1)}% of maxmemory ({new Date(a.at * 1000).toLocaleString('en-GB')}).
                                    </div>
                                ))}
                            </div>
                        )}

                        <div className={card}>
                            <div className="flex flex-wrap items-center gap-2 justify-between">
                                <div className="flex flex-wrap gap-2" role="tablist">
                                    {instances.map((i) => (
                                        <button
                                            key={i.port}
                                            role="tab"
                                            aria-selected={port === i.port}
                                            onClick={() => setPort(i.port)}
                                            className={`px-3 py-1.5 rounded-md text-sm border ${port === i.port ? 'bg-indigo-600 text-white border-indigo-600' : 'border-gray-300 dark:border-gray-700 hover:bg-gray-100 dark:hover:bg-gray-800'}`}
                                        >
                                            {i.label}
                                            {alertFor(i.port) && <span className="ml-1 text-red-500">●</span>}
                                        </button>
                                    ))}
                                </div>
                                <div className="flex gap-1" role="group" aria-label="Window">
                                    {WINDOWS.map(([k, label]) => (
                                        <button
                                            key={k}
                                            onClick={() => setWindowName(k)}
                                            aria-pressed={windowName === k}
                                            className={`px-3 py-1.5 rounded-md text-sm border ${windowName === k ? 'bg-gray-800 text-white dark:bg-gray-200 dark:text-gray-900' : 'border-gray-300 dark:border-gray-700 hover:bg-gray-100 dark:hover:bg-gray-800'}`}
                                        >
                                            {label}
                                        </button>
                                    ))}
                                </div>
                            </div>
                            <div className="mt-2 text-xs text-gray-500 dark:text-gray-400" data-testid="redis-status">
                                {status ? (status.ok ? `Last history pull ${new Date(status.at * 1000).toLocaleTimeString('en-GB')}, ${status.added} new samples.` : `Last history pull failed: ${status.error}`) : 'No history pull yet. The scheduler runs it every minute.'}
                                {error && ` Page refresh failed: ${error}.`}
                            </div>
                        </div>

                        {!payload && <div className={card}>Loading...</div>}

                        {payload && s.samples === 0 && (
                            <div className={card} data-testid="redis-empty">
                                No samples in this window yet.{windowName === 'live' ? ' The scheduler starts polling within a minute of opening Live.' : ''}
                            </div>
                        )}

                        {payload && s.samples > 0 && (
                            <>
                                {s.stale && windowName !== 'live' && (
                                    <div className="rounded-lg border border-amber-300 bg-amber-50 dark:bg-amber-950 dark:border-amber-800 p-3 text-amber-800 dark:text-amber-200 text-sm" data-testid="redis-stale">
                                        Newest sample is {fmtUptime(s.ageSec)} old: the collector or the connection is not delivering.
                                    </div>
                                )}
                                <div className="grid grid-cols-2 lg:grid-cols-6 gap-3">
                                    <Stat testid="stat-memory" label="Memory" value={fmtBytes(s.memNow)} sub={s.maxNow > 0 ? `${fmtPct(s.memPct, 1)} of ${fmtBytes(s.maxNow)}` : 'no limit'} />
                                    <Stat testid="stat-ops" label="Ops/s" value={fmtRate(s.opsAvg)} sub={`peak ${fmtRate(s.opsPeak)}`} />
                                    <Stat testid="stat-bandwidth" label="Bandwidth" value={fmtBytes(s.bytes)} sub={`in ${fmtBytes(s.rx)} · out ${fmtBytes(s.tx)}`} />
                                    <Stat testid="stat-keys" label="Keys" value={fmtNum(s.keysNow)} sub={`hit rate ${fmtPct(s.hitRate, 1)}`} />
                                    <Stat testid="stat-clients" label="Clients" value={fmtNum(s.cliNow)} sub={`${fmtNum(s.blockedNow)} blocked`} />
                                    <Stat testid="stat-uptime" label="Uptime" value={fmtUptime(s.uptimeSec)} sub={`v${s.version || '?'}${s.restarts ? ` · ${s.restarts} restart(s) in window` : ''}`} />
                                </div>
                                <div className="flex items-center gap-2">
                                    <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${PILL[level]}`} data-testid="redis-memory-pill">
                                        storage {s.memPct === null ? 'no limit' : fmtPct(s.memPct, 1)}
                                    </span>
                                    {Number(s.evictedNow) > 0 && <span className="px-2 py-0.5 rounded-full text-xs font-medium bg-red-100 text-red-800 dark:bg-red-900 dark:text-red-200">{fmtNum(s.evictedNow)} keys evicted since start</span>}
                                </div>

                                <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                                    <Chart title="Throughput (ops/s)" testid="chart-ops" series={payload.series} windowName={windowName} lines={lines.ops} fmt={fmtRate} />
                                    <Chart title="Storage (used of max)" testid="chart-mem" series={payload.series} windowName={windowName} lines={lines.mem} fmt={fmtBytes} />
                                    <Chart title="Bandwidth (bytes/s)" testid="chart-net" series={payload.series} windowName={windowName} lines={lines.net} fmt={(v) => `${fmtBytes(v)}/s`} />
                                    <Chart title="Hits and misses per bucket" testid="chart-hits" series={payload.series} windowName={windowName} lines={lines.hits} fmt={fmtNum} />
                                    <Chart title="Keys" testid="chart-keys" series={payload.series} windowName={windowName} lines={lines.keys} fmt={fmtNum} />
                                    <Chart title="Connected clients" testid="chart-cli" series={payload.series} windowName={windowName} lines={lines.cli} fmt={fmtNum} />
                                </div>

                                <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                                    <div className={card}>
                                        <div className="text-sm font-medium mb-2 text-gray-800 dark:text-gray-200">Top commands</div>
                                        {payload.topCommands.length === 0 ? (
                                            <div className="text-sm text-gray-500">No command counters yet. They appear after the first poll of this panel.</div>
                                        ) : (
                                            <table className="w-full text-sm" data-testid="top-commands">
                                                <thead>
                                                    <tr className="text-left text-gray-500 dark:text-gray-400">
                                                        <th className="py-1">Command</th>
                                                        <th className="py-1 text-right">calls/s (window)</th>
                                                        <th className="py-1 text-right">calls since start</th>
                                                        <th className="py-1 text-right">share</th>
                                                    </tr>
                                                </thead>
                                                <tbody>
                                                    {payload.topCommands.map((c) => (
                                                        <tr key={c.cmd} className="border-t border-gray-100 dark:border-gray-800">
                                                            <td className="py-1 font-mono">{c.cmd}</td>
                                                            <td className="py-1 text-right">{fmtRate(c.rate)}</td>
                                                            <td className="py-1 text-right">{fmtNum(c.calls)}</td>
                                                            <td className="py-1 text-right">{fmtPct(c.share, 1)}</td>
                                                        </tr>
                                                    ))}
                                                </tbody>
                                            </table>
                                        )}
                                    </div>
                                    <div className={card}>
                                        <div className="text-sm font-medium mb-2 text-gray-800 dark:text-gray-200">Keys per database</div>
                                        <table className="w-full text-sm" data-testid="keys-per-db">
                                            <thead>
                                                <tr className="text-left text-gray-500 dark:text-gray-400">
                                                    <th className="py-1">DB</th>
                                                    <th className="py-1 text-right">keys</th>
                                                </tr>
                                            </thead>
                                            <tbody>
                                                {Object.entries(payload.dbs || {}).map(([db, n]) => (
                                                    <tr key={db} className="border-t border-gray-100 dark:border-gray-800">
                                                        <td className="py-1 font-mono">db{db}</td>
                                                        <td className="py-1 text-right">{fmtNum(n)}</td>
                                                    </tr>
                                                ))}
                                            </tbody>
                                        </table>
                                    </div>
                                </div>
                            </>
                        )}
                    </>
                )}
            </div>
        </AuthenticatedLayout>
    );
}
