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
<title>PHP Diagnostic</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Share+Tech+Mono&family=Barlow+Condensed:wght@300;400;500;600;700&display=swap" rel="stylesheet">
<style>
  :root {
    --bg:        #03050a;
    --surface:   #070c12;
    --panel:     #060a10;
    --border:    rgba(180,130,40,.18);
    --border-hi: rgba(220,160,50,.45);
    --text:      #9a8f78;
    --text-hi:   #c8b98a;
    --amber:     #d4940a;
    --amber-hi:  #f0b030;
    --amber-glow:#ffcc55;
    --green:     #38a060;
    --green-hi:  #4dc878;
    --red:       #b83030;
    --red-hi:    #e04848;
    --blue:      #2878a8;
    --blue-hi:   #40a0d8;
    --muted:     #e8d0a0;
    --mono:      'Share Tech Mono', monospace;
    --cond:      'Barlow Condensed', sans-serif;
  }

  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  html { scroll-behavior: smooth; }

  body {
    background: var(--bg);
    background-image:
      radial-gradient(ellipse 80% 50% at 50% -10%, rgba(180,110,10,.06) 0%, transparent 60%),
      linear-gradient(rgba(180,130,40,.025) 1px, transparent 1px),
      linear-gradient(90deg, rgba(180,130,40,.025) 1px, transparent 1px);
    background-size: 100% 100%, 40px 40px, 40px 40px;
    color: var(--text);
    font-family: var(--mono);
    font-size: 12px;
    line-height: 1.6;
    min-height: 100vh;
    padding: 28px 28px 72px;
  }

  /* ── scanline overlay ───────────── */
  body::before {
    content: '';
    position: fixed;
    inset: 0;
    background: repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(0,0,0,.06) 2px,
      rgba(0,0,0,.06) 4px
    );
    pointer-events: none;
    z-index: 9999;
  }

  /* ══════════════════════════════════
     HEADER
  ══════════════════════════════════ */
  header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 16px;
    margin-bottom: 36px;
    padding-bottom: 18px;
    border-bottom: 1px solid var(--border);
    position: relative;
  }

  header::after {
    content: '';
    position: absolute;
    bottom: -1px; left: 0;
    width: 220px;
    height: 1px;
    background: linear-gradient(90deg, var(--amber), transparent);
  }

  .logo {
    display: flex;
    flex-direction: column;
    gap: 3px;
  }

  .logo-main {
    font-family: var(--cond);
    font-weight: 700;
    font-size: 22px;
    letter-spacing: .14em;
    text-transform: uppercase;
    color: var(--amber-hi);
    display: flex;
    align-items: center;
    gap: 10px;
  }

  .logo-main::before {
    content: '//';
    color: var(--amber);
    opacity: .6;
    font-family: var(--mono);
    font-size: 14px;
  }

  .logo-sub {
    font-size: 12px;
    letter-spacing: .18em;
    text-transform: uppercase;
    color: var(--muted);
    padding-left: 24px;
  }

  .header-right {
    display: flex;
    flex-direction: column;
    align-items: flex-end;
    gap: 5px;
  }

  .badge {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    padding: 4px 12px 4px 10px;
    font-family: var(--cond);
    font-size: 11px;
    font-weight: 600;
    letter-spacing: .18em;
    text-transform: uppercase;
    border: 1px solid;
    clip-path: polygon(6px 0%, 100% 0%, calc(100% - 6px) 100%, 0% 100%);
  }

  .badge.on  { color: var(--green-hi); border-color: rgba(77,200,120,.35); background: rgba(60,160,96,.07); }
  .badge.off { color: var(--red-hi);   border-color: rgba(224,72,72,.35);  background: rgba(184,48,48,.07); }

  .badge-dot {
    width: 5px; height: 5px;
    border-radius: 50%;
    background: currentColor;
    box-shadow: 0 0 5px currentColor;
    animation: blink 2.4s ease-in-out infinite;
  }

  @keyframes blink { 0%,100%{opacity:1} 50%{opacity:.2} }

  .meta {
    font-size: 12px;
    letter-spacing: .08em;
    color: var(--muted);
  }

  /* ══════════════════════════════════
     SECTION TITLE
  ══════════════════════════════════ */
  .section-title {
    display: flex;
    align-items: center;
    gap: 10px;
    margin: 30px 0 12px;
    font-family: var(--cond);
    font-size: 12px;
    font-weight: 600;
    letter-spacing: .22em;
    text-transform: uppercase;
    color: var(--amber);
  }

  .section-title::before {
    content: '▸';
    font-size: 12px;
    opacity: .7;
  }

  .section-title::after {
    content: '';
    flex: 1;
    height: 1px;
    background: linear-gradient(90deg, var(--border-hi), transparent);
  }

  /* ══════════════════════════════════
     HUD CARD  (corner-bracket style)
  ══════════════════════════════════ */
  .card {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 18px 20px 16px;
    position: relative;
    overflow: hidden;
    transition: border-color .25s, box-shadow .25s;
  }

  .card::before,
  .card::after {
    content: '';
    position: absolute;
    width: 12px; height: 12px;
    transition: width .25s, height .25s;
  }

  .card::before {
    top: -1px; left: -1px;
    border-top: 2px solid var(--amber);
    border-left: 2px solid var(--amber);
  }

  .card::after {
    bottom: -1px; right: -1px;
    border-bottom: 2px solid var(--amber);
    border-right: 2px solid var(--amber);
  }

  .card:hover {
    border-color: var(--border-hi);
    box-shadow: 0 0 20px rgba(212,148,10,.06), inset 0 0 20px rgba(212,148,10,.03);
  }

  .card:hover::before,
  .card:hover::after { width: 20px; height: 20px; }

  .card-label {
    font-family: var(--cond);
    font-size: 12px;
    font-weight: 500;
    letter-spacing: .20em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 10px;
  }

  .card-value {
    font-family: var(--cond);
    font-weight: 300;
    font-size: 38px;
    letter-spacing: .02em;
    color: var(--amber-hi);
    line-height: 1;
    margin-bottom: 5px;
  }

  .card-sub {
    font-size: 10px;
    color: var(--muted);
    letter-spacing: .04em;
  }

  .card-value.c-amber  { color: var(--amber-hi); }
  .card-value.c-green  { color: var(--green-hi); text-shadow: 0 0 12px rgba(77,200,120,.4); }
  .card-value.c-red    { color: var(--red-hi);   text-shadow: 0 0 12px rgba(224,72,72,.4); }
  .card-value.c-blue   { color: var(--blue-hi);  }
  .card-value.c-white  { color: var(--text-hi);  }

  /* ══════════════════════════════════
     PROGRESS BAR  (segmented HUD)
  ══════════════════════════════════ */
  .bar-wrap {
    margin-top: 14px;
    height: 5px;
    background: rgba(180,130,40,.08);
    position: relative;
    overflow: hidden;
  }

  .bar-wrap::before {
    content: '';
    position: absolute;
    inset: 0;
    background: repeating-linear-gradient(
      90deg, transparent 0px, transparent 9px, var(--bg) 9px, var(--bg) 10px
    );
    z-index: 1;
  }

  .bar {
    height: 100%;
    background: var(--amber);
    box-shadow: 2px 0 8px var(--amber);
    transition: width .8s cubic-bezier(.4,0,.2,1);
    position: relative;
  }

  .bar.b-green  { background: var(--green);  box-shadow: 2px 0 8px var(--green-hi); }
  .bar.b-red    { background: var(--red);    box-shadow: 2px 0 8px var(--red-hi); }
  .bar.b-amber  { background: var(--amber);  box-shadow: 2px 0 8px var(--amber-hi); }

  .bar-labels {
    display: flex;
    justify-content: space-between;
    margin-top: 5px;
    font-size: 12px;
    letter-spacing: .06em;
    color: var(--muted);
  }

  /* ══════════════════════════════════
     GRIDS
  ══════════════════════════════════ */
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 12px;
    margin-bottom: 12px;
  }

  .restart-grid {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }

  .two-col {
    display: grid;
    grid-template-columns: repeat(3, 1fr);
    gap: 12px;
  }

  /* ══════════════════════════════════
     TABLE CARD
  ══════════════════════════════════ */
  .table-card {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 2px 18px;
    position: relative;
  }

  .table-card::before {
    content: '';
    position: absolute;
    top: 0; left: 0;
    width: 2px; height: 100%;
    background: linear-gradient(180deg, var(--amber), transparent);
    opacity: .4;
  }

  .stat-table {
    width: 100%;
    border-collapse: collapse;
  }

  .stat-table tr { border-bottom: 1px solid var(--border); }
  .stat-table tr:last-child { border-bottom: none; }

  .stat-table td {
    padding: 8px 4px;
    vertical-align: middle;
    font-size: 12px;
  }

  .stat-table td:first-child { color: var(--muted); }
  .stat-table td:last-child  { color: var(--text-hi); text-align: right; }

  /* ══════════════════════════════════
     KV-CARD GRID  (compact multi-col)
  ══════════════════════════════════ */
  .kv-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(180px, 1fr));
    gap: 8px;
  }

  .kv-card {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 10px 14px;
    display: flex;
    flex-direction: column;
    gap: 4px;
    transition: border-color .2s;
    position: relative;
  }

  .kv-card::before {
    content: '';
    position: absolute;
    top: 0; left: 0;
    width: 100%; height: 2px;
    background: linear-gradient(90deg, rgba(212,148,10,.25), transparent);
  }

  .kv-card:hover { border-color: var(--border-hi); }

  .kv-card-key {
    font-size: 12px;
    color: var(--muted);
    letter-spacing: .04em;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .kv-card-val {
    font-size: 13px;
    color: var(--text-hi);
    word-break: break-all;
    line-height: 1.3;
  }

  .kv-card-val.on   { color: var(--green-hi); }
  .kv-card-val.off  { color: var(--red-hi); }
  .kv-card-val.warn { color: var(--amber-hi); }

  /* limit variant — also shows a status tag */
  .kv-card-footer {
    margin-top: 6px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 8px;
  }

  .kv-card-sub {
    font-size: 12px;
    color: var(--muted);
  }

  /* ══════════════════════════════════
     KV + LIMIT ROWS
  ══════════════════════════════════ */
  .kv-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 8px 0;
    border-bottom: 1px solid var(--border);
    font-size: 12px;
  }

  .kv-row:last-child { border-bottom: none; }
  .kv-key  { color: var(--muted); flex-shrink: 0; letter-spacing: .04em; }
  .kv-val  { color: var(--text-hi); text-align: right; word-break: break-all; max-width: 65%; }
  .kv-val.on   { color: var(--green-hi); }
  .kv-val.off  { color: var(--red-hi); }
  .kv-val.warn { color: var(--amber-hi); }

  .limit-row {
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    padding: 9px 0;
    border-bottom: 1px solid var(--border);
  }

  .limit-row:last-child { border-bottom: none; }

  .limit-left { display: flex; flex-direction: column; gap: 2px; }
  .limit-key  { color: var(--muted); font-size: 12px; letter-spacing: .06em; }
  .limit-val  { color: var(--text-hi); font-size: 12px; }
  .limit-right { flex-shrink: 0; }

  /* ══════════════════════════════════
     STATUS TAGS  (angular, not pills)
  ══════════════════════════════════ */
  .tag {
    display: inline-block;
    font-family: var(--cond);
    font-size: 12px;
    font-weight: 600;
    letter-spacing: .16em;
    text-transform: uppercase;
    padding: 2px 8px;
    border: 1px solid;
    clip-path: polygon(4px 0%, 100% 0%, calc(100% - 4px) 100%, 0% 100%);
  }

  .tag-ok   { color: var(--green-hi); border-color: rgba(77,200,120,.35); background: rgba(60,160,96,.08); }
  .tag-miss { color: var(--red-hi);   border-color: rgba(224,72,72,.35);  background: rgba(184,48,48,.08); }
  .tag-warn { color: var(--amber-hi); border-color: rgba(240,176,48,.35); background: rgba(212,148,10,.08); }
  .tag-off  { color: var(--muted);    border-color: rgba(90,80,60,.3);    background: rgba(30,25,15,.4); }
  .tag-info { color: var(--blue-hi);  border-color: rgba(64,160,216,.3);  background: rgba(40,120,168,.08); }

  /* ══════════════════════════════════
     DIRECTIVES
  ══════════════════════════════════ */
  .dir-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(260px, 1fr));
    gap: 8px;
  }

  .dir-item {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 9px 14px;
    display: flex;
    justify-content: space-between;
    align-items: center;
    gap: 12px;
    transition: border-color .2s;
  }

  .dir-item:hover { border-color: var(--border-hi); }
  .dir-key { color: var(--muted); font-size: 12px; word-break: break-all; }
  .dir-val { color: var(--amber-hi); font-size: 12px; white-space: nowrap; }

  /* ══════════════════════════════════
     EXTENSION GRID
  ══════════════════════════════════ */
  .ext-grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(240px, 1fr));
    gap: 8px;
  }

  .ext-item {
    background: var(--panel);
    border: 1px solid var(--border);
    padding: 9px 14px;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 10px;
    transition: border-color .2s;
  }

  .ext-item:hover { border-color: var(--border-hi); }
  .ext-item.missing { border-color: rgba(224,72,72,.25); background: rgba(184,48,48,.03); }
  .ext-left { display: flex; flex-direction: column; gap: 2px; }
  .ext-name { font-size: 12px; color: var(--text-hi); }
  .ext-item.missing .ext-name { color: var(--red-hi); }
  .ext-note { font-size: 12px; color: var(--muted); letter-spacing: .04em; }

  /* ══════════════════════════════════
     DISABLED NOTICE
  ══════════════════════════════════ */
  .notice {
    border: 1px solid rgba(224,72,72,.25);
    background: rgba(184,48,48,.05);
    padding: 28px;
    color: var(--red-hi);
    text-align: center;
    font-family: var(--cond);
    letter-spacing: .06em;
  }

  /* ══════════════════════════════════
     FOOTER
  ══════════════════════════════════ */
  footer {
    margin-top: 56px;
    padding-top: 18px;
    border-top: 1px solid var(--border);
    color: var(--muted);
    font-size: 12px;
    letter-spacing: .08em;
    display: flex;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 8px;
  }

  /* ══════════════════════════════════
     PILL alias (keep compat)
  ══════════════════════════════════ */
  .pill       { display:inline-block; font-family:var(--cond); font-size:12px; font-weight:600; letter-spacing:.16em; text-transform:uppercase; padding:2px 8px; border:1px solid; clip-path:polygon(4px 0%,100% 0%,calc(100% - 4px) 100%,0% 100%); }
  .pill-ok    { color:var(--green-hi); border-color:rgba(77,200,120,.35);  background:rgba(60,160,96,.08); }
  .pill-miss  { color:var(--red-hi);   border-color:rgba(224,72,72,.35);   background:rgba(184,48,48,.08); }
  .pill-warn  { color:var(--amber-hi); border-color:rgba(240,176,48,.35);  background:rgba(212,148,10,.08); }
  .pill-off   { color:var(--muted);    border-color:rgba(90,80,60,.3);     background:rgba(30,25,15,.4); }
  .pill-info  { color:var(--blue-hi);  border-color:rgba(64,160,216,.3);   background:rgba(40,120,168,.08); }

  /* ══════════════════════════════════
     ANIMATIONS
  ══════════════════════════════════ */
  .card, .dir-item, .table-card, .ext-item {
    animation: scanIn .35s ease both;
  }

  @keyframes scanIn {
    from { opacity: 0; clip-path: inset(0 100% 0 0); }
    to   { opacity: 1; clip-path: inset(0 0% 0 0); }
  }

  .card:nth-child(1) { animation-delay: .04s; }
  .card:nth-child(2) { animation-delay: .10s; }
  .card:nth-child(3) { animation-delay: .16s; }
  .card:nth-child(4) { animation-delay: .22s; }

  /* sub-label inside section for optional/required groups */
  .sub-label {
    font-family: var(--cond);
    font-size: 12px;
    font-weight: 600;
    letter-spacing: .20em;
    text-transform: uppercase;
    color: var(--muted);
    margin-bottom: 8px;
    margin-top: 0;
    padding-left: 2px;
    border-left: 2px solid var(--muted);
    padding-left: 7px;
  }
</style>
</head>
<body>

<header>
  <div class="logo">
    <div class="logo-main">PHP Diagnostic</div>
    <div class="logo-sub">PHP <?= PHP_VERSION ?> &nbsp;·&nbsp; <?= php_uname('n') ?></div>
  </div>
  <div class="header-right">
    <?php if ($enabled && ($status['opcache_enabled'] ?? false)): ?>
      <span class="badge on"><span class="badge-dot"></span>OPcache Active</span>
    <?php else: ?>
      <span class="badge off"><span class="badge-dot"></span>OPcache Inactive</span>
    <?php endif; ?>
    <span class="meta"><?= date('Y-m-d  H:i:s T') ?></span>
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
    $hrClass  = $hr >= 90 ? 'c-green' : ($hr >= 70 ? 'c-amber' : 'c-red');
    $barClass = $hr >= 90 ? 'b-green' : ($hr >= 70 ? 'b-amber' : 'b-red');
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
    $memClass = $memPct < 70 ? 'b-green' : ($memPct < 90 ? 'b-amber' : 'b-red');
  ?>
  <div class="card">
    <div class="card-label">Memory Usage</div>
    <div class="card-value c-amber"><?= fmt_bytes($mem_used) ?></div>
    <div class="card-sub">of <?= fmt_bytes($mem_total) ?> total &nbsp;·&nbsp; <?= fmt_bytes($mem_free) ?> free</div>
    <div class="bar-wrap"><div class="bar <?= $memClass ?>" style="width:<?= $memPct ?>%"></div></div>
    <div class="bar-labels"><span>Used <?= $memPct ?>%</span><span><?= fmt_bytes($mem_wasted) ?> wasted</span></div>
  </div>

  <!-- Cached scripts / keys -->
  <?php $keyPct = pct($keys_used, $keys_total); ?>
  <div class="card">
    <div class="card-label">Cached Scripts</div>
    <div class="card-value c-white"><?= number_format($keys_used) ?></div>
    <div class="card-sub">of <?= number_format($keys_total) ?> max keys</div>
    <div class="bar-wrap"><div class="bar b-amber" style="width:<?= $keyPct ?>%"></div></div>
    <div class="bar-labels"><span><?= $keyPct ?>% full</span><span><?= number_format($keys_total - $keys_used) ?> free</span></div>
  </div>

  <!-- Interned strings -->
  <?php $strPct = pct($strings_used, $strings_buf); $strBarClass = $strPct < 70 ? 'b-green' : ($strPct < 90 ? 'b-amber' : 'b-red'); ?>
  <div class="card">
    <div class="card-label">Interned Strings</div>
    <div class="card-value c-blue"><?= fmt_bytes($strings_used) ?></div>
    <div class="card-sub">of <?= fmt_bytes($strings_buf) ?> buffer &nbsp;·&nbsp; <?= fmt_bytes($strings_free) ?> free</div>
    <div class="bar-wrap"><div class="bar <?= $strBarClass ?>" style="width:<?= $strPct ?>%"></div></div>
    <div class="bar-labels"><span><?= $strPct ?>% used</span><span>&nbsp;</span></div>
  </div>

</div>

<!-- ── Restarts ── -->
<div class="section-title">Restarts</div>
<div class="restart-grid">
  <?php foreach ([
    ['Out of Memory', $restarts_oom,  $restarts_oom  > 0 ? 'c-red'   : 'c-green'],
    ['Hash',          $restarts_hash, $restarts_hash > 0 ? 'c-amber' : 'c-green'],
    ['Manual',        $restarts_man,  'c-white'],
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
<?php
  $stats = $status['opcache_statistics'] ?? [];
  $statRows = [
    ['Start Time',       date('Y-m-d H:i:s', $stats['start_time'] ?? 0), ''],
    ['Last Restart',     ($stats['last_restart_time'] ?? 0) ? date('Y-m-d H:i:s', $stats['last_restart_time']) : 'Never', ''],
    ['Total Hits',       number_format($stats['hits']   ?? 0), ''],
    ['Total Misses',     number_format($stats['misses'] ?? 0), ''],
    ['Blacklist Misses', number_format($stats['blacklist_misses'] ?? 0), ''],
    ['Cached Scripts',   number_format($stats['num_cached_scripts'] ?? 0), ''],
    ['Max Cached Keys',  number_format($stats['max_cached_keys']   ?? 0), ''],
  ];
?>
<div class="kv-grid">
  <?php foreach ($statRows as [$k, $v, $cls]): ?>
  <div class="kv-card">
    <span class="kv-card-key"><?= htmlspecialchars($k) ?></span>
    <span class="kv-card-val <?= $cls ?>"><?= htmlspecialchars($v) ?></span>
  </div>
  <?php endforeach; ?>
</div>

<!-- ── Memory Detail ── -->
<div class="section-title">Memory Detail</div>
<div class="kv-grid">
  <?php foreach ([
    ['Used Memory',       fmt_bytes($mem_used),                          ''],
    ['Free Memory',       fmt_bytes($mem_free),                          ''],
    ['Wasted Memory',     fmt_bytes($mem_wasted),                        $mem_wasted > 0 ? 'warn' : ''],
    ['Wasted %',          pct($mem_wasted, $mem_total) . '%',            ''],
    ['Total Memory',      fmt_bytes($mem_total),                         ''],
  ] as [$k, $v, $cls]): ?>
  <div class="kv-card">
    <span class="kv-card-key"><?= $k ?></span>
    <span class="kv-card-val <?= $cls ?>"><?= $v ?></span>
  </div>
  <?php endforeach; ?>
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
<div class="kv-grid">
  <?php foreach ($res_limits as [$key, $display, $bytes, $minOk, $minGood]):
    $isTime = str_contains($key, 'time');
    $raw    = $isTime ? (int)$bytes : $bytes;
    if ($raw === 0 || $raw === -1) { $pillClass = 'pill-warn'; $pillText = 'Unlimited'; }
    elseif ($raw < $minOk)         { $pillClass = 'pill-miss'; $pillText = 'Low'; }
    elseif ($raw < $minGood)       { $pillClass = 'pill-warn'; $pillText = 'OK'; }
    else                           { $pillClass = 'pill-ok';   $pillText = 'Good'; }
  ?>
  <div class="kv-card">
    <span class="kv-card-key"><?= htmlspecialchars($key) ?></span>
    <span class="kv-card-val"><?= htmlspecialchars($display) ?></span>
    <div class="kv-card-footer">
      <span class="pill <?= $pillClass ?>"><?= $pillText ?></span>
    </div>
  </div>
  <?php endforeach; ?>
</div>

<!-- ── Upload & Post ── -->
<div class="section-title">Upload &amp; Post Limits</div>
<div class="kv-grid">
  <?php foreach ($upload as [$key, $display, $bytes, $minOk, $minGood]):
    $isCount = $key === 'max_file_uploads';
    $raw = (int)$bytes;
    if ($raw < $minOk)       { $pillClass = 'pill-miss'; $pillText = 'Low'; }
    elseif ($raw < $minGood) { $pillClass = 'pill-warn'; $pillText = 'OK'; }
    else                     { $pillClass = 'pill-ok';   $pillText = 'Good'; }
    $valDisplay = $isCount ? htmlspecialchars($display) : htmlspecialchars($display) . ' <span style="color:var(--muted);font-size:12px;">(' . fmt_bytes($bytes) . ')</span>';
  ?>
  <div class="kv-card">
    <span class="kv-card-key"><?= htmlspecialchars($key) ?></span>
    <span class="kv-card-val"><?= $valDisplay ?></span>
    <div class="kv-card-footer">
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
<div class="kv-grid">
  <?php foreach ($misc_cfg as $k => $v):
    $cls = '';
    if ($k === 'allow_url_include' && $v === 'On') $cls = 'off';
    if ($k === 'date.timezone' && $v === '(not set)') $cls = 'warn';
  ?>
  <div class="kv-card">
    <span class="kv-card-key"><?= htmlspecialchars($k) ?></span>
    <span class="kv-card-val <?= $cls ?>"><?= htmlspecialchars($v) ?></span>
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

<p style="font-size:12px;color:var(--muted);margin-bottom:12px;">
  <span class="pill pill-ok">Loaded</span>&nbsp; extension is present &nbsp;·&nbsp;
  <span class="pill pill-miss">Missing</span>&nbsp; extension not detected &nbsp;·&nbsp;
  <span class="pill pill-off">Optional</span>&nbsp; recommended but not required
</p>

<div class="sub-label" style="margin-bottom:8px;">Required</div>
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

<div class="sub-label" style="margin-bottom:8px;margin-top:4px;">Recommended / Optional</div>
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
  <span>PHP Diagnostic &nbsp;·&nbsp; Self-contained diagnostic script</span>
  <span>Generated at <?= date('H:i:s') ?></span>
</footer>

</body>
</html>
