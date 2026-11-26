export const fmtBytes = (n) => {
    if (n === null || n === undefined || Number.isNaN(n)) return '-';
    const u = ['B', 'KB', 'MB', 'GB', 'TB'];
    let i = 0;
    let v = Math.abs(n);
    while (v >= 1024 && i < u.length - 1) {
        v /= 1024;
        i++;
    }
    return `${n < 0 ? '-' : ''}${v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)} ${u[i]}`;
};

export const fmtNum = (n) => (n === null || n === undefined ? '-' : Math.round(n).toLocaleString('en-US'));

export const fmtRate = (n) => (n === null || n === undefined ? '-' : n >= 100 ? n.toFixed(0) : n >= 10 ? n.toFixed(1) : n.toFixed(2));

export const fmtPct = (n, digits = 0) => (n === null || n === undefined ? '-' : `${(n * 100).toFixed(digits)}%`);

export const fmtUptime = (s) => {
    if (s === null || s === undefined) return '-';
    const d = Math.floor(s / 86400);
    const h = Math.floor((s % 86400) / 3600);
    const m = Math.floor((s % 3600) / 60);
    return d ? `${d}d ${h}h` : h ? `${h}h ${m}m` : `${m}m`;
};

/** Storage pill colour: amber from 75 %, red from 90 % (same lines as the alerts). */
export const memLevel = (pct) => (pct === null || pct === undefined ? 'none' : pct >= 0.9 ? 'red' : pct >= 0.75 ? 'amber' : 'ok');

export const labelFor = (t, windowName) => {
    const d = new Date(t * 1000);
    const hm = d.toLocaleTimeString('en-GB', { hour: '2-digit', minute: '2-digit', second: windowName === 'live' ? '2-digit' : undefined });
    return windowName === '7d' || windowName === '1d' ? `${d.toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })} ${hm}` : hm;
};
