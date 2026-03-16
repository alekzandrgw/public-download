<?php
// ── OPcache Stats Dashboard ────────────────────────────────────────────────

$enabled = function_exists('opcache_get_status');
$status  = $enabled ? opcache_get_status(false) : null;
$config  = $enabled ? opcache_get_configuration()  : null;

function fmt_bytes(int $b): string {
    if ($b >= 1073741824) return round($b / 1073741824, 2) . ' GB';
    if ($b >= 1048576)    return round($b / 1048576,    2) . ' MB';
    if ($b >= 1024)       return round($b / 1024,       2) . ' KB';
    return $b . ' B';
}

function pct(float $used, float $total): float {
    return $total > 0 ? round($used / $total * 100, 1) : 0;
}

$mem_used  = $status['memory_usage']['used_memory']          ?? 0;
$mem_free  = $status['memory_usage']['free_memory']          ?? 0;
$mem_wasted= $status['memory_usage']['wasted_memory']        ?? 0;
$mem_total = $mem_used + $mem_free + $mem_wasted;

$hit_count = $status['opcache_statistics']['hits']           ?? 0;
$miss_count= $status['opcache_statistics']['misses']         ?? 0;
$hit_rate  = $status['opcache_statistics']['opcache_hit_rate']?? 0;

$keys_used = $status['opcache_statistics']['num_cached_scripts'] ?? 0;
$keys_total= $status['opcache_statistics']['max_cached_keys']    ?? 1;

$strings_buf = $status['interned_strings_usage']['buffer_size']  ?? 0;
$strings_used= $status['interned_strings_usage']['used_memory']  ?? 0;
$strings_free= $status['interned_strings_usage']['free_memory']  ?? 0;

$restarts_oom = $status['opcache_statistics']['oom_restarts']    ?? 0;
$restarts_hash= $status['opcache_statistics']['hash_restarts']   ?? 0;
$restarts_man = $status['opcache_statistics']['manual_restarts'] ?? 0;

$ini = $config['directives'] ?? [];

// ── PHP / WordPress-relevant values ───────────────────────────────────────

function ini_bytes(string $key): int {
    $v = trim(ini_get($key));
    if ($v === '') return 0;
    $last = strtolower($v[strlen($v)-1]);
    $num  = (int)$v;
    switch ($last) {
        case 'g': $num *= 1024;
        case 'm': $num *= 1024;
        case 'k': $num *= 1024;
    }
    return $num;
}

function ext_ok(string $name): bool {
    return extension_loaded($name);
}

// PHP environment
$php_env = [
    'PHP Version'         => PHP_VERSION,
    'SAPI'                => PHP_SAPI,
    'OS'                  => PHP_OS_FAMILY,
    'Architecture'        => PHP_INT_SIZE === 8 ? '64-bit' : '32-bit',
    'Zend Engine'         => zend_version(),
    'Thread Safety'       => defined('ZEND_THREAD_SAFE') && ZEND_THREAD_SAFE ? 'Enabled (ZTS)' : 'Disabled (NTS)',
];

// Resource limits
$res_limits = [
    ['memory_limit',       ini_get('memory_limit'),      ini_bytes('memory_limit'), 128*1024*1024, 256*1024*1024],
    ['max_execution_time', ini_get('max_execution_time').'s', (int)ini_get('max_execution_time'), 30, 60],
    ['max_input_time',     ini_get('max_input_time').'s',     (int)ini_get('max_input_time'),     60, 120],
    ['max_input_vars',     ini_get('max_input_vars'),    (int)ini_get('max_input_vars'),    1000, 3000],
];

// Upload / post
$upload = [
    ['upload_max_filesize', ini_get('upload_max_filesize'), ini_bytes('upload_max_filesize'), 8*1024*1024, 64*1024*1024],
    ['post_max_size',       ini_get('post_max_size'),       ini_bytes('post_max_size'),       8*1024*1024, 64*1024*1024],
    ['max_file_uploads',    ini_get('max_file_uploads'),    (int)ini_get('max_file_uploads'), 5, 20],
];

// Error handling
$error_cfg = [
    'display_errors'         => ini_get('display_errors'),
    'log_errors'             => ini_get('log_errors'),
    'error_log'              => ini_get('error_log') ?: '(not set)',
    'error_reporting'        => ini_get('error_reporting'),
    'html_errors'            => ini_get('html_errors'),
];

// Session
$session_cfg = [
    'session.save_handler'  => ini_get('session.save_handler'),
    'session.save_path'     => ini_get('session.save_path') ?: '(default)',
    'session.gc_maxlifetime'=> ini_get('session.gc_maxlifetime').'s',
    'session.cookie_secure' => ini_get('session.cookie_secure') ? 'On' : 'Off',
    'session.cookie_httponly'=> ini_get('session.cookie_httponly') ? 'On' : 'Off',
];

// Misc
$misc_cfg = [
    'default_charset'   => ini_get('default_charset'),
    'date.timezone'     => ini_get('date.timezone') ?: '(not set)',
    'allow_url_fopen'   => ini_get('allow_url_fopen') ? 'On' : 'Off',
    'allow_url_include' => ini_get('allow_url_include') ? 'On' : 'Off',
    'file_uploads'      => ini_get('file_uploads') ? 'On' : 'Off',
    'disable_functions' => ini_get('disable_functions') ?: '(none)',
    'open_basedir'      => ini_get('open_basedir') ?: '(not set)',
];

// Extensions relevant to WordPress
$wp_extensions = [
    // Core required
    ['mysqli',      'MySQLi',        true,  'Required – database'],
    ['curl',        'cURL',          true,  'Required – HTTP requests'],
    ['json',        'JSON',          true,  'Required – REST API'],
    ['mbstring',    'mbstring',      true,  'Required – multibyte strings'],
    ['openssl',     'OpenSSL',       true,  'Required – SSL/HTTPS'],
    ['xml',         'XML',           true,  'Required – feeds/sitemaps'],
    ['zip',         'Zip',           true,  'Required – plugin/theme install'],
    // Recommended
    ['gd',          'GD',            false, 'Image processing'],
    ['imagick',     'Imagick',       false, 'Image processing (preferred)'],
    ['intl',        'intl',          false, 'Internationalisation'],
    ['sodium',      'Sodium',        false, 'Cryptography (WP 5.2+)'],
    ['exif',        'Exif',          false, 'Image metadata'],
    ['fileinfo',    'FileInfo',      false, 'MIME detection'],
    ['bcmath',      'BCMath',        false, 'Arbitrary precision math'],
    ['pcre',        'PCRE',          false, 'Regex (almost always present)'],
    // Caching / performance
    ['redis',       'Redis',         false, 'Object cache backend'],
    ['memcached',   'Memcached',     false, 'Object cache backend'],
    ['apcu',        'APCu',          false, 'Local object cache'],
    // DB alternatives
    ['pdo',         'PDO',           false, 'PDO (some plugins)'],
    ['pdo_mysql',   'PDO MySQL',     false, 'PDO MySQL driver'],
];
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>OPcache Dashboard</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Space+Mono:wght@400;700&family=Syne:wght@400;600;800&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:       #0a0c10;
    --surface:  #111318;
    --border:   #1e2230;
    --border2:  #2a3045;
    --text:     #c9d1e0;
    --muted:    #4a5370;
    --accent:   #5af0a0;
    --accent2:  #3dd8ff;
    --warn:     #f0c05a;
    --danger:   #f05a6a;
    --radius:   6px;
    --mono:     'Space Mono', monospace;
    --sans:     'Syne', sans-serif;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: var(--mono);
    font-size: 13px;
    line-height: 1.6;
    min-height: 100vh;
    padding: 32px 24px 64px;
  }

  /* ── header ──────────────────────────── */
  header {
    display: flex;
    align-items: flex-end;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 12px;
    margin-bottom: 40px;
    padding-bottom: 20px;
    border-bottom: 1px solid var(--border);
  }

  .logo {
    font-family: var(--sans);
    font-weight: 800;
    font-size: 26px;
    letter-spacing: -0.5px;
    color: #fff;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .logo span {
    color: var(--accent);
  }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    padding: 4px 12px;
    border-radius: 999px;
    font-size: 11px;
    font-weight: 700;
    letter-spacing: 0.08em;
    text-transform: uppercase;
  }

  .badge.on  { background: rgba(90,240,160,.12); color: var(--accent);  border: 1px solid rgba(90,240,160,.25); }
  .badge.off { background: rgba(240,90,106,.12); color: var(--danger);  border: 1px solid rgba(240,90,106,.25); }

  .badge::before {
    content: '';
    width: 6px; height: 6px;
    border-radius: 50%;
    background: currentColor;
    animation: pulse 2s ease-in-out infinite;
  }

  @keyframes pulse {
    0%,100% { opacity: 1; }
    50%      { opacity: .3; }
  }

  .meta { color: var(--muted); font-size: 11px; }

  /* ── grid ────────────────────────────── */
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
    gap: 16px;
    margin-bottom: 16px;
  }

  /* ── card ────────────────────────────── */
  .card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 20px 22px;
    position: relative;
    overflow: hidden;
    transition: border-color .2s;
  }

  .card:hover { border-color: var(--border2); }

  .card::before {
    content: '';
    position: absolute;
    inset: 0 0 auto 0;
    height: 2px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    opacity: 0;
    transition: opacity .2s;
  }

  .card:hover::before { opacity: 1; }

  .card-label {
    font-family: var(--sans);
    font-size: 10px;
    font-weight: 600;
    letter-spacing: .12em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 10px;
  }

  .card-value {
    font-family: var(--sans);
    font-size: 32px;
    font-weight: 800;
    color: #fff;
    line-height: 1;
    margin-bottom: 6px;
    letter-spacing: -1px;
  }

  .card-sub { color: var(--muted); font-size: 11px; }

  .card-value.accent  { color: var(--accent);  }
  .card-value.accent2 { color: var(--accent2); }
  .card-value.warn    { color: var(--warn);    }
  .card-value.danger  { color: var(--danger);  }

  /* ── progress bar ────────────────────── */
  .bar-wrap {
    margin-top: 14px;
    background: var(--border);
    border-radius: 999px;
    height: 6px;
    overflow: hidden;
  }

  .bar {
    height: 100%;
    border-radius: 999px;
    background: linear-gradient(90deg, var(--accent), var(--accent2));
    transition: width .6s cubic-bezier(.4,0,.2,1);
  }

  .bar.warn   { background: linear-gradient(90deg, var(--warn),   #f08850); }
  .bar.danger { background: linear-gradient(90deg, var(--danger), #c03070); }

  .bar-labels {
    display: flex;
    justify-content: space-between;
    margin-top: 6px;
    font-size: 10px;
    color: var(--muted);
  }

  /* ── section title ───────────────────── */
  .section-title {
    font-family: var(--sans);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: .14em;
    text-transform: uppercase;
    color: var(--muted);
    margin: 32px 0 12px;
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .section-title::after {
    content: '';
    flex: 1;
    height: 1px;
    background: var(--border);
  }

  /* ── stat table ──────────────────────── */
  .stat-table {
    width: 100%;
    border-collapse: collapse;
  }

  .stat-table tr { border-bottom: 1px solid var(--border); }
  .stat-table tr:last-child { border-bottom: none; }

  .stat-table td {
    padding: 9px 12px;
    vertical-align: middle;
  }

  .stat-table td:first-child { color: var(--muted); padding-left: 0; }
  .stat-table td:last-child  { color: #fff; text-align: right; padding-right: 0; }

  /* ── table card ──────────────────────── */
  .table-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 6px 22px;
  }

  /* ── directives ──────────────────────── */
  .dir-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(340px, 1fr));
    gap: 16px;
  }

  .dir-item {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 12px 16px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    transition: border-color .2s;
  }

  .dir-item:hover { border-color: var(--border2); }

  .dir-key {
    color: var(--muted);
    font-size: 11px;
    word-break: break-all;
  }

  .dir-val { color: var(--accent2); font-size: 12px; white-space: nowrap; }

  /* ── restart cards ───────────────────── */
  .restart-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 16px;
  }

  /* ── footer ──────────────────────────── */
  footer {
    margin-top: 48px;
    padding-top: 20px;
    border-top: 1px solid var(--border);
    color: var(--muted);
    font-size: 11px;
    display: flex;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
  }

  /* ── disabled notice ─────────────────── */
  .notice {
    background: rgba(240,90,106,.07);
    border: 1px solid rgba(240,90,106,.2);
    border-radius: var(--radius);
    padding: 24px;
    color: var(--danger);
    text-align: center;
    font-family: var(--sans);
  }

  /* ── status pill ─────────────────────────── */
  .pill {
    display: inline-block;
    padding: 2px 9px;
    border-radius: 999px;
    font-size: 10px;
    font-weight: 700;
    letter-spacing: .06em;
    text-transform: uppercase;
  }
  .pill-ok   { background: rgba(90,240,160,.12); color: var(--accent);  border: 1px solid rgba(90,240,160,.2); }
  .pill-miss { background: rgba(240,90,106,.12); color: var(--danger);  border: 1px solid rgba(240,90,106,.2); }
  .pill-warn { background: rgba(240,192,90,.12); color: var(--warn);    border: 1px solid rgba(240,192,90,.2); }
  .pill-info { background: rgba(61,216,255,.10); color: var(--accent2); border: 1px solid rgba(61,216,255,.2); }
  .pill-off  { background: rgba(74,83,112,.12);  color: var(--muted);   border: 1px solid rgba(74,83,112,.3); }

  /* ── extension grid ──────────────────────── */
  .ext-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 10px;
  }
  .ext-item {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: var(--radius);
    padding: 11px 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    transition: border-color .2s;
  }
  .ext-item:hover { border-color: var(--border2); }
  .ext-item.missing { border-color: rgba(240,90,106,.30); }
  .ext-left  { display: flex; flex-direction: column; gap: 2px; }
  .ext-name  { font-size: 12px; color: var(--text); }
  .ext-item.missing .ext-name { color: var(--danger); }
  .ext-note  { font-size: 10px; color: var(--muted); }

  /* ── kv / limit rows ────────────────────── */
  .kv-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 9px 0;
    border-bottom: 1px solid var(--border);
    font-size: 12px;
  }
  .kv-row:last-child { border-bottom: none; }
  .kv-key  { color: var(--muted); flex-shrink: 0; }
  .kv-val  { color: #fff; text-align: right; word-break: break-all; max-width: 65%; }
  .kv-val.on    { color: var(--accent); }
  .kv-val.off   { color: var(--danger); }
  .kv-val.warn  { color: var(--warn);   }
  .kv-val.muted { color: var(--muted);  }

  .limit-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 10px 0;
    border-bottom: 1px solid var(--border);
  }
  .limit-row:last-child { border-bottom: none; }
  .limit-left { display: flex; flex-direction: column; gap: 3px; }
  .limit-key  { color: var(--muted); font-size: 11px; }
  .limit-val  { color: #fff; font-size: 13px; }
  .limit-right { flex-shrink: 0; }

  /* ── two column layout ───────────────────── */
  .two-col {
    display: grid;
    grid-template-columns: 1fr 1fr;
    gap: 16px;
  }
  @media (max-width: 640px) { .two-col { grid-template-columns: 1fr; } }

  /* ── animations ──────────────────────── */
  .card, .dir-item, .table-card {
    animation: fadeUp .4s ease both;
  }

  @keyframes fadeUp {
    from { opacity: 0; transform: translateY(10px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  .card:nth-child(1) { animation-delay: .05s; }
  .card:nth-child(2) { animation-delay: .10s; }
  .card:nth-child(3) { animation-delay: .15s; }
  .card:nth-child(4) { animation-delay: .20s; }
</style>
</head>
<body>

<header>
  <div>
    <div class="logo">OP<span>cache</span> Dashboard</div>
    <div class="meta">PHP <?= PHP_VERSION ?> &nbsp;·&nbsp; <?= php_uname('n') ?></div>
  </div>
  <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">
    <?php if ($enabled && ($status['opcache_enabled'] ?? false)): ?>
      <span class="badge on">Enabled</span>
    <?php else: ?>
      <span class="badge off">Disabled</span>
    <?php endif; ?>
    <span class="meta"><?= date('Y-m-d H:i:s T') ?></span>
  </div>
</header>

<?php if (!$enabled || !$status): ?>
  <div class="notice">
    OPcache is not available on this PHP installation.<br>
    <small>Enable the <code>opcache</code> extension in your php.ini to use this dashboard.</small>
  </div>
<?php else: ?>

<!-- ── Overview KPIs ── -->
<div class="section-title">Overview</div>
<div class="grid">

  <!-- Hit rate -->
  <?php
    $hr = round($hit_rate, 1);
    $hrClass = $hr >= 90 ? 'accent' : ($hr >= 70 ? 'warn' : 'danger');
    $barClass = $hr >= 90 ? ''       : ($hr >= 70 ? 'warn'  : 'danger');
  ?>
  <div class="card">
    <div class="card-label">Hit Rate</div>
    <div class="card-value <?= $hrClass ?>"><?= $hr ?>%</div>
    <div class="card-sub"><?= number_format($hit_count) ?> hits &nbsp;/&nbsp; <?= number_format($miss_count) ?> misses</div>
    <div class="bar-wrap"><div class="bar <?= $barClass ?>" style="width:<?= $hr ?>%"></div></div>
    <div class="bar-labels"><span>0%</span><span>100%</span></div>
  </div>

  <!-- Memory -->
  <?php
    $memPct   = pct($mem_used + $mem_wasted, $mem_total);
    $memClass = $memPct < 70 ? '' : ($memPct < 90 ? 'warn' : 'danger');
  ?>
  <div class="card">
    <div class="card-label">Memory Usage</div>
    <div class="card-value accent2"><?= fmt_bytes($mem_used) ?></div>
    <div class="card-sub">of <?= fmt_bytes($mem_total) ?> total &nbsp;·&nbsp; <?= fmt_bytes($mem_free) ?> free</div>
    <div class="bar-wrap"><div class="bar <?= $memClass ?>" style="width:<?= $memPct ?>%"></div></div>
    <div class="bar-labels"><span>Used <?= $memPct ?>%</span><span><?= fmt_bytes($mem_wasted) ?> wasted</span></div>
  </div>

  <!-- Cached scripts / keys -->
  <?php $keyPct = pct($keys_used, $keys_total); ?>
  <div class="card">
    <div class="card-label">Cached Scripts</div>
    <div class="card-value"><?= number_format($keys_used) ?></div>
    <div class="card-sub">of <?= number_format($keys_total) ?> max keys</div>
    <div class="bar-wrap"><div class="bar" style="width:<?= $keyPct ?>%"></div></div>
    <div class="bar-labels"><span><?= $keyPct ?>% full</span><span><?= number_format($keys_total - $keys_used) ?> free</span></div>
  </div>

  <!-- Interned strings -->
  <?php $strPct = pct($strings_used, $strings_buf); $strClass = $strPct < 70 ? '' : ($strPct < 90 ? 'warn' : 'danger'); ?>
  <div class="card">
    <div class="card-label">Interned Strings</div>
    <div class="card-value accent"><?= fmt_bytes($strings_used) ?></div>
    <div class="card-sub">of <?= fmt_bytes($strings_buf) ?> buffer &nbsp;·&nbsp; <?= fmt_bytes($strings_free) ?> free</div>
    <div class="bar-wrap"><div class="bar <?= $strClass ?>" style="width:<?= $strPct ?>%"></div></div>
    <div class="bar-labels"><span><?= $strPct ?>% used</span><span>&nbsp;</span></div>
  </div>

</div>

<!-- ── Restarts ── -->
<div class="section-title">Restarts</div>
<div class="restart-grid">
  <?php foreach ([
    ['Out of Memory', $restarts_oom,  $restarts_oom  > 0 ? 'danger' : 'accent'],
    ['Hash',          $restarts_hash, $restarts_hash > 0 ? 'warn'   : 'accent'],
    ['Manual',        $restarts_man,  ''],
  ] as [$label, $val, $cls]): ?>
  <div class="card">
    <div class="card-label"><?= $label ?> Restarts</div>
    <div class="card-value <?= $cls ?>"><?= number_format($val) ?></div>
    <div class="card-sub"><?= $val > 0 ? '⚠ Non-zero — investigate' : 'All clear' ?></div>
  </div>
  <?php endforeach; ?>
</div>

<!-- ── Statistics ── -->
<div class="section-title">Statistics</div>
<div class="table-card">
  <table class="stat-table">
    <?php
      $stats = $status['opcache_statistics'] ?? [];
      $rows = [
        ['Start Time',          date('Y-m-d H:i:s', $stats['start_time']          ?? 0)],
        ['Last Restart Time',   ($stats['last_restart_time'] ?? 0)
                                  ? date('Y-m-d H:i:s', $stats['last_restart_time'])
                                  : 'Never'],
        ['Total Hits',          number_format($stats['hits']    ?? 0)],
        ['Total Misses',        number_format($stats['misses']  ?? 0)],
        ['Blacklist Misses',    number_format($stats['blacklist_misses'] ?? 0)],
        ['Cached Scripts',      number_format($stats['num_cached_scripts'] ?? 0)],
        ['Max Cached Keys',     number_format($stats['max_cached_keys']    ?? 0)],
      ];
    ?>
    <?php foreach ($rows as [$k, $v]): ?>
    <tr><td><?= htmlspecialchars($k) ?></td><td><?= htmlspecialchars($v) ?></td></tr>
    <?php endforeach; ?>
  </table>
</div>

<!-- ── Memory Detail ── -->
<div class="section-title">Memory Detail</div>
<div class="table-card">
  <table class="stat-table">
    <?php foreach ([
      ['Used Memory',       fmt_bytes($mem_used)],
      ['Free Memory',       fmt_bytes($mem_free)],
      ['Wasted Memory',     fmt_bytes($mem_wasted)],
      ['Wasted Percentage', pct($mem_wasted, $mem_total) . '%'],
      ['Total',             fmt_bytes($mem_total)],
    ] as [$k, $v]): ?>
    <tr><td><?= $k ?></td><td><?= $v ?></td></tr>
    <?php endforeach; ?>
  </table>
</div>

<!-- ── Directives ── -->
<?php if (!empty($ini)): ?>
<div class="section-title">Configuration Directives</div>
<div class="dir-grid">
  <?php foreach ($ini as $key => $val): ?>
  <div class="dir-item">
    <span class="dir-key"><?= htmlspecialchars($key) ?></span>
    <span class="dir-val">
      <?php
        if (is_bool($val)) echo $val ? 'On' : 'Off';
        elseif (is_int($val) && str_contains(strtolower($key), 'memory'))
          echo fmt_bytes($val);
        else echo htmlspecialchars((string)$val);
      ?>
    </span>
  </div>
  <?php endforeach; ?>
</div>
<?php endif; ?>

<?php endif; // end opcache check ?>

<!-- ═══════════════════════════════════════════════════════════════════════ -->
<!-- ── WordPress / PHP Server Info ──────────────────────────────────────── -->
<!-- ═══════════════════════════════════════════════════════════════════════ -->

<!-- ── PHP Environment ── -->
<div class="section-title">PHP Environment</div>
<div class="two-col">
  <div class="table-card">
    <?php foreach ($php_env as $k => $v): ?>
    <div class="kv-row">
      <span class="kv-key"><?= htmlspecialchars($k) ?></span>
      <span class="kv-val"><?= htmlspecialchars($v) ?></span>
    </div>
    <?php endforeach; ?>
  </div>

  <!-- Server software -->
  <div class="table-card">
    <?php
    $server_rows = [
      'Server Software'  => $_SERVER['SERVER_SOFTWARE']  ?? '(unknown)',
      'Server Protocol'  => $_SERVER['SERVER_PROTOCOL']  ?? '(unknown)',
      'HTTPS'            => (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') || ($_SERVER['SERVER_PORT'] ?? '') == '443' ? 'Yes' : 'No',
      'Document Root'    => $_SERVER['DOCUMENT_ROOT']    ?? '(unknown)',
      'Server Addr'      => $_SERVER['SERVER_ADDR']      ?? '(unknown)',
      'Request Time'     => date('Y-m-d H:i:s', (int)($_SERVER['REQUEST_TIME'] ?? time())),
    ];
    foreach ($server_rows as $k => $v):
      $cls = '';
      if ($k === 'HTTPS')  $cls = $v === 'Yes' ? 'on' : 'off';
    ?>
    <div class="kv-row">
      <span class="kv-key"><?= htmlspecialchars($k) ?></span>
      <span class="kv-val <?= $cls ?>"><?= htmlspecialchars($v) ?></span>
    </div>
    <?php endforeach; ?>
  </div>
</div>

<!-- ── Resource Limits ── -->
<div class="section-title">Resource Limits</div>
<div class="table-card">
  <?php foreach ($res_limits as [$key, $display, $bytes, $minOk, $minGood]):
    // For execution times the "bytes" are actually seconds
    $isTime = str_contains($key, 'time');
    $raw    = $isTime ? (int)$bytes : $bytes;

    if ($raw === 0 || $raw === -1) { // unlimited
      $pillClass = 'pill-warn'; $pillText = 'Unlimited';
    } elseif ($raw < $minOk) {
      $pillClass = 'pill-miss'; $pillText = 'Low';
    } elseif ($raw < $minGood) {
      $pillClass = 'pill-warn'; $pillText = 'OK';
    } else {
      $pillClass = 'pill-ok';   $pillText = 'Good';
    }
  ?>
  <div class="limit-row">
    <div class="limit-left">
      <span class="limit-key"><?= htmlspecialchars($key) ?></span>
      <span class="limit-val"><?= htmlspecialchars($display) ?></span>
    </div>
    <div class="limit-right">
      <span class="pill <?= $pillClass ?>"><?= $pillText ?></span>
    </div>
  </div>
  <?php endforeach; ?>
</div>

<!-- ── Upload & Post ── -->
<div class="section-title">Upload &amp; Post Limits</div>
<div class="table-card">
  <?php foreach ($upload as [$key, $display, $bytes, $minOk, $minGood]):
    $isCount = $key === 'max_file_uploads';
    $raw = (int)$bytes;
    if ($raw < $minOk)   { $pillClass = 'pill-miss'; $pillText = 'Low'; }
    elseif ($raw < $minGood) { $pillClass = 'pill-warn'; $pillText = 'OK'; }
    else                  { $pillClass = 'pill-ok';   $pillText = 'Good'; }
  ?>
  <div class="limit-row">
    <div class="limit-left">
      <span class="limit-key"><?= htmlspecialchars($key) ?></span>
      <span class="limit-val">
        <?= $isCount
              ? htmlspecialchars($display)
              : htmlspecialchars($display) . ' <span style="color:var(--muted);font-size:10px;">(' . fmt_bytes($bytes) . ')</span>'
        ?>
      </span>
    </div>
    <div class="limit-right">
      <span class="pill <?= $pillClass ?>"><?= $pillText ?></span>
    </div>
  </div>
  <?php endforeach; ?>
</div>

<!-- ── Error Handling ── -->
<div class="section-title">Error Handling &amp; Logging</div>
<div class="two-col">
  <div class="table-card">
    <?php
    foreach ($error_cfg as $k => $v):
      $cls = '';
      if ($k === 'display_errors') $cls = $v ? 'warn' : 'on'; // off is good in prod
      if ($k === 'log_errors')     $cls = $v ? 'on'   : 'off';
    ?>
    <div class="kv-row">
      <span class="kv-key"><?= htmlspecialchars($k) ?></span>
      <span class="kv-val <?= $cls ?>"><?= htmlspecialchars($v) ?></span>
    </div>
    <?php endforeach; ?>
  </div>

  <!-- Session -->
  <div class="table-card">
    <?php foreach ($session_cfg as $k => $v): ?>
    <div class="kv-row">
      <span class="kv-key"><?= htmlspecialchars($k) ?></span>
      <span class="kv-val"><?= htmlspecialchars($v) ?></span>
    </div>
    <?php endforeach; ?>
  </div>
</div>

<!-- ── Miscellaneous ── -->
<div class="section-title">Miscellaneous</div>
<div class="table-card">
  <?php foreach ($misc_cfg as $k => $v):
    $cls = '';
    if ($k === 'allow_url_include' && $v === 'On') $cls = 'off'; // bad
    if ($k === 'date.timezone' && $v === '(not set)') $cls = 'warn';
  ?>
  <div class="kv-row">
    <span class="kv-key"><?= htmlspecialchars($k) ?></span>
    <span class="kv-val <?= $cls ?>"><?= htmlspecialchars($v) ?></span>
  </div>
  <?php endforeach; ?>
</div>

<!-- ── Extensions ── -->
<div class="section-title">WordPress-Relevant Extensions</div>

<?php
  // Group: required (required=true) vs recommended (required=false)
  $required = array_filter($wp_extensions, fn($e) => $e[2]);
  $optional = array_filter($wp_extensions, fn($e) => !$e[2]);
?>

<p style="font-size:11px;color:var(--muted);margin-bottom:12px;">
  <span class="pill pill-ok">Loaded</span>&nbsp; extension is present &nbsp;·&nbsp;
  <span class="pill pill-miss">Missing</span>&nbsp; extension not detected &nbsp;·&nbsp;
  <span class="pill pill-off">Optional</span>&nbsp; recommended but not required
</p>

<div style="margin-bottom:10px;font-family:var(--sans);font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);">Required</div>
<div class="ext-grid" style="margin-bottom:20px;">
  <?php foreach ($required as [$ext, $label, $req, $note]):
    $loaded = ext_ok($ext);
  ?>
  <div class="ext-item <?= $loaded ? '' : 'missing' ?>">
    <div class="ext-left">
      <span class="ext-name"><?= htmlspecialchars($label) ?></span>
      <span class="ext-note"><?= htmlspecialchars($note) ?></span>
    </div>
    <span class="pill <?= $loaded ? 'pill-ok' : 'pill-miss' ?>"><?= $loaded ? 'Loaded' : 'Missing' ?></span>
  </div>
  <?php endforeach; ?>
</div>

<div style="margin-bottom:10px;font-family:var(--sans);font-size:10px;letter-spacing:.1em;text-transform:uppercase;color:var(--muted);">Recommended / Optional</div>
<div class="ext-grid">
  <?php foreach ($optional as [$ext, $label, $req, $note]):
    $loaded = ext_ok($ext);
  ?>
  <div class="ext-item">
    <div class="ext-left">
      <span class="ext-name"><?= htmlspecialchars($label) ?></span>
      <span class="ext-note"><?= htmlspecialchars($note) ?></span>
    </div>
    <span class="pill <?= $loaded ? 'pill-ok' : 'pill-off' ?>"><?= $loaded ? 'Loaded' : 'Optional' ?></span>
  </div>
  <?php endforeach; ?>
</div>

<footer>
  <span>OPcache + WordPress PHP Dashboard &nbsp;·&nbsp; Self-contained PHP script</span>
  <span>Generated at <?= date('H:i:s') ?></span>
</footer>

</body>
</html>
