'use strict';
'require view';
'require form';
'require network';
'require fs';
'require ui';
'require poll';

// Severity -> CSS color (matches wg-split-doctor's OK/WARN/FIXABLE/FAIL).
var SEV = {
	OK:      '#3c763d',
	WARN:    '#8a6d3b',
	FIXABLE: '#a0522d',
	FAIL:    '#a94442'
};

// Inject the panel's stylesheet once. Kept self-contained (no theme assets) so
// it renders identically on bootstrap/material/dark — colors use the SEV palette
// plus translucent tints that read on both light and dark backgrounds.
var STYLE_ID = 'wg-split-style';
function injectStyle() {
	if (document.getElementById(STYLE_ID)) return;
	// Theme-aware surfaces: follow the active theme's CSS custom properties where
	// present (Argon exposes --border-color / accent vars and renders .cbi-section
	// as a rounded card), but every var() carries a translucent-grey fallback so
	// the panel is identical on stock Bootstrap/material, which define none of them.
	var BORDER = 'var(--border-color, rgba(127,127,127,.35))';
	var SURFACE = 'var(--off-color, rgba(127,127,127,.07))';
	var css = '' +
		'.wgs-hero{display:flex;align-items:center;gap:1em;padding:1em 1.2em;border-radius:.5em;margin:.4em 0 1em;border:1px solid ' + BORDER + '}' +
		'.wgs-hero-icon{font-size:2.2em;line-height:1;width:1.4em;text-align:center;flex:0 0 auto}' +
		'.wgs-hero-main{flex:1 1 auto;min-width:0}' +
		'.wgs-hero-path{font-size:1.25em;font-weight:bold;margin-bottom:.15em}' +
		'.wgs-hero-meta{font-size:.9em;opacity:.85}' +
		'.wgs-hero-meta span{margin-right:1em;white-space:nowrap}' +
		'.wgs-chain{display:flex;flex-wrap:wrap;align-items:stretch;gap:.35em;margin:.2em 0 1em}' +
		'.wgs-node{display:flex;flex-direction:column;justify-content:center;padding:.45em .7em;border-radius:.45em;' +
			'border:1px solid ' + BORDER + ';background:' + SURFACE + ';text-align:center;min-width:78px}' +
		'.wgs-node-title{font-weight:600;font-size:.95em}' +
		'.wgs-node-sub{font-size:.78em;opacity:.75;margin-top:.1em}' +
		'.wgs-node-active{border-color:' + SEV.OK + ';background:rgba(60,118,61,.14);box-shadow:0 0 0 2px rgba(60,118,61,.3)}' +
		'.wgs-node-dead{border-color:' + SEV.FAIL + ';color:' + SEV.FAIL + ';opacity:.85}' +
		'.wgs-node-block{border-color:' + SEV.FAIL + ';background:rgba(169,68,66,.14);box-shadow:0 0 0 2px rgba(169,68,66,.3)}' +
		'.wgs-arrow{align-self:center;opacity:.5;font-size:1.1em;padding:0 .1em}' +
		'.wgs-check{display:flex;flex-wrap:wrap;align-items:center;gap:.5em;margin:.4em 0;padding:.5em .7em;' +
			'border-radius:.35em;border-left:4px solid #777;background:' + SURFACE + '}' +
		'.wgs-check-body{flex:1 1 240px;min-width:0}' +
		'.wgs-check-fix{opacity:.8;font-size:.88em;margin-top:.15em}' +
		'.wgs-firstrun{padding:1em 1.2em;border-radius:.5em;border:1px dashed ' + BORDER + ';' +
			'background:rgba(138,109,59,.1);margin:.4em 0 1em}' +
		'.wgs-firstrun h4{margin:.2em 0 .5em}' +
		'.wgs-firstrun ol{margin:.3em 0 .6em 1.2em}' +
		'.wgs-badge{display:inline-block;padding:.1em .5em;border-radius:.25em;color:#fff;font-weight:bold;font-size:.85em}' +
		'.wgs-toolbar{margin:.2em 0 .8em;display:flex;flex-wrap:wrap;gap:.4em;align-items:center}' +
		'.wgs-spacer{flex:1 1 auto}' +
		'.wgs-live{font-size:.82em;opacity:.7;display:inline-flex;align-items:center;gap:.35em}' +
		'.wgs-dot{width:.6em;height:.6em;border-radius:50%;background:' + SEV.OK + ';display:inline-block}' +
		'.wgs-dot-off{background:#999}';
	var el = document.createElement('style');
	el.id = STYLE_ID;
	el.textContent = css;
	document.head.appendChild(el);
}

function badge(sev) {
	return E('span', { 'class': 'wgs-badge', 'style': 'background:' + (SEV[sev] || '#777') }, sev);
}

function yn(v) {
	return E('span', { 'style': 'color:' + (v ? SEV.OK : SEV.FAIL) + ';font-weight:600' }, v ? '✓' : '✗');
}

// Doctor is passive: per-endpoint health is handshake-derived — 'ok' (fresh) /
// 'idle' (stale, not probed). 'OK'/'FAIL' only appear if a future active probe
// is added. The daemon-confirmed live tunnel is shown as the Active path above.
function healthCell(h) {
	if (h === 'OK' || h === 'ok') return E('span', { 'style': 'color:' + SEV.OK }, _('ok'));
	if (h === 'FAIL') return E('span', { 'style': 'color:' + SEV.FAIL }, 'FAIL');
	if (h === 'idle') return E('span', { 'style': 'color:#888' }, _('idle'));
	return '—';
}

function fmtAge(s) {
	if (s == null || s < 0) return '—';
	if (s < 120) return s + 's';
	if (s < 7200) return Math.round(s / 60) + 'm';
	return Math.round(s / 3600) + 'h';
}

// Active-path state -> { icon, label, sev } for the hero. The hero severity is
// the worst overall finding; the path label is the human reading of doctor's
// `state` field ("vpn:<iface>" | "zapret" | "wan" | "killswitch").
function pathInfo(state, overall) {
	var icon = '✓', sev = overall || 'FAIL', label;
	if (/^vpn:/.test(state)) {
		label = _('VPN active via %s').format(state.replace(/^vpn:/, ''));
	} else if (state === 'zapret') {
		label = _('No tunnel — WAN with zapret DPI-bypass');
	} else if (state === 'killswitch') {
		label = _('Kill switch — policy traffic blocked'); icon = '⛔';
	} else if (state === 'wan') {
		label = _('No tunnel — direct WAN (traffic exposed)');
	} else {
		label = _('Unknown'); icon = '?';
	}
	if (sev === 'OK') icon = (state && /^vpn:/.test(state)) ? '✓' : icon;
	else if (sev === 'WARN') icon = (icon === '✓' ? '⚠' : icon);
	else if (sev === 'FAIL' || sev === 'FIXABLE') icon = (icon === '✓' ? '✕' : icon);
	return { icon: icon, label: label, sev: sev };
}

function heroCard(d) {
	var s = d.summary || {};
	var pi = pathInfo(s.state || '', d.overall);
	var color = SEV[pi.sev] || '#777';
	var meta = E('div', { 'class': 'wgs-hero-meta' }, [
		E('span', {}, [ E('strong', {}, _('Mode') + ': '), (s.mode || '?') ]),
		E('span', {}, [ E('strong', {}, _('Kill switch') + ': '),
			(String(s.killswitch) === '1' ? _('on') : _('off')) ]),
		E('span', {}, [ E('strong', {}, _('Failures') + ': '),
			(s.fail_count != null ? String(s.fail_count) : '?') ]),
		E('span', {}, [ E('strong', {}, _('LAN') + ': '),
			(s.lan_iface || '?') + ' → ' + (s.lan_cidr || _('(none detected)')) ])
	]);
	return E('div', { 'class': 'wgs-hero', 'style': 'border-left:5px solid ' + color },[
		E('div', { 'class': 'wgs-hero-icon', 'style': 'color:' + color }, pi.icon),
		E('div', { 'class': 'wgs-hero-main' }, [
			E('div', { 'class': 'wgs-hero-path' }, pi.label),
			meta
		]),
		E('div', { 'style': 'flex:0 0 auto' }, badge(d.overall || 'FAIL'))
	]);
}

// The routing chain, left to right, with the live hop highlighted:
//   LAN → [tunnel #1] → [tunnel #N] → (zapret) → WAN
// Tunnels are doctor's endpoints (already priority-ordered). A tunnel that is
// present but stale reads neutral; a missing/down one reads dead. Whichever hop
// matches the active state lights up green (or red for the killswitch block).
function chainViz(d) {
	var s = d.summary || {};
	var state = s.state || '';
	var nodes = [];

	function node(title, sub, cls) {
		return E('div', { 'class': 'wgs-node' + (cls ? ' ' + cls : '') }, [
			E('div', { 'class': 'wgs-node-title' }, title),
			sub ? E('div', { 'class': 'wgs-node-sub' }, sub) : ''
		]);
	}
	function arrow() { return E('div', { 'class': 'wgs-arrow' }, '→'); }

	nodes.push(node(_('LAN'), s.lan_iface || '', ''));

	(d.endpoints || []).forEach(function (e) {
		var active = (state === 'vpn:' + e.iface);
		var cls = active ? 'wgs-node-active' : (e.present ? '' : 'wgs-node-dead');
		var sub = !e.present ? _('down') : (e.handshake_age >= 0 ? '⇄ ' + fmtAge(e.handshake_age) : '');
		nodes.push(arrow());
		nodes.push(node('#' + (e.priority || '?') + ' ' + e.iface, sub, cls));
	});

	// zapret rung (only meaningful when enabled — show if doctor reported it or it's the live path)
	var hasZapret = (d.lists || []).some(function (l) { return l.name === 'nozapret'; }) || state === 'zapret';
	if (hasZapret) {
		nodes.push(arrow());
		nodes.push(node(_('zapret'), _('DPI-bypass'), state === 'zapret' ? 'wgs-node-active' : ''));
	}

	nodes.push(arrow());
	if (state === 'killswitch') {
		nodes.push(node(_('blocked'), _('kill switch'), 'wgs-node-block'));
	} else {
		nodes.push(node(_('WAN'), _('direct'), state === 'wan' ? 'wgs-node-active' : ''));
	}

	return E('div', { 'class': 'wgs-chain' }, nodes);
}

// A contextual deep-link for a check, so the operator can jump straight to the
// page that fixes it instead of decoding the SSH command. Firewall findings ->
// the firewall app; a missing interface -> the interfaces app. Null otherwise
// (the `→ fix:` line still spells out the CLI command).
function checkLink(c) {
	if (c.category === 'firewall')
		return E('a', { 'class': 'btn cbi-button cbi-button-neutral', 'href': L.url('admin/network/firewall') },
			_('Firewall settings'));
	if (c.category === 'endpoint' && /does not exist|configured but down/.test(c.message || ''))
		return E('a', { 'class': 'btn cbi-button cbi-button-neutral', 'href': L.url('admin/network/network') },
			_('Network interfaces'));
	return null;
}

function statusPanel(wgIfaces) {
	injectStyle();
	var body = E('div', {}, E('em', _('Loading diagnostics…')));
	var liveOn = true;

	function firstRun(d) {
		// No tunnels configured yet — the box can't split-route. Guide the user to
		// the two prerequisites: a WG/AWG interface, then a Failover-tunnels row.
		if ((d.endpoints || []).length) return null;
		var steps = [];
		if (!wgIfaces || !wgIfaces.length) {
			steps.push(E('li', {}, [
				_('Create a WireGuard/AmneziaWG interface under '),
				E('a', { 'href': L.url('admin/network/network') }, _('Network → Interfaces')),
				_(' (wg-split does not manage keys/peers).')
			]));
		} else {
			steps.push(E('li', {}, _('You have %d WireGuard/AmneziaWG interface(s) — good.').format(wgIfaces.length)));
		}
		steps.push(E('li', {}, _('Add it below under “Failover tunnels” with a priority, then Save & Apply.')));
		steps.push(E('li', {}, _('Put the tunnel interface in a firewall zone (masq on) and allow forwarding lan → that zone.')));
		return E('div', { 'class': 'wgs-firstrun' }, [
			E('h4', {}, '👋 ' + _('Let’s get the first tunnel routing')),
			E('p', {}, _('No failover tunnels are configured yet, so all LAN traffic currently exits over plain WAN.')),
			E('ol', {}, steps)
		]);
	}

	function render(d) {
		var fr = firstRun(d);

		// endpoints table
		var epRows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('Tunnel')), E('th', { 'class': 'th' }, _('Prio')),
			E('th', { 'class': 'th' }, _('Handshake')), E('th', { 'class': 'th' }, _('Health')),
			E('th', { 'class': 'th' }, _('Zone')), E('th', { 'class': 'th' }, _('Masq')),
			E('th', { 'class': 'th' }, _('LAN fwd'))
		]) ];
		(d.endpoints || []).forEach(function (e) {
			epRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, e.present ? e.iface : E('span', { 'style': 'color:' + SEV.FAIL }, e.iface + ' ' + _('(missing)'))),
				E('td', { 'class': 'td' }, e.priority || '—'),
				E('td', { 'class': 'td' }, e.present ? fmtAge(e.handshake_age) : '—'),
				E('td', { 'class': 'td' }, healthCell(e.health)),
				E('td', { 'class': 'td' }, e.zone || E('span', { 'style': 'color:' + SEV.FAIL }, _('none'))),
				E('td', { 'class': 'td' }, yn(e.masq)),
				E('td', { 'class': 'td' }, yn(e.forwarding))
			]));
		});

		// lists table
		var listRows = [ E('tr', { 'class': 'tr table-titles' }, [
			E('th', { 'class': 'th' }, _('List')), E('th', { 'class': 'th' }, _('Entries')),
			E('th', { 'class': 'th' }, _('Min')), E('th', { 'class': 'th' }, _('Age')),
			E('th', { 'class': 'th' }, _('State'))
		]) ];
		(d.lists || []).forEach(function (l) {
			listRows.push(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, l.name),
				E('td', { 'class': 'td' }, l.enabled ? l.count : _('(disabled)')),
				E('td', { 'class': 'td' }, l.min),
				E('td', { 'class': 'td' }, fmtAge(l.age)),
				E('td', { 'class': 'td' }, l.enabled ? yn(l.ok) : '—')
			]));
		});

		// checks that need attention (hide the OK noise; doctor only emits problems anyway)
		var checks = (d.checks || []).filter(function (c) { return c.severity !== 'OK'; });
		var checkNodes;
		if (!checks.length) {
			checkNodes = E('p', { 'style': 'color:' + SEV.OK + ';font-weight:600' }, '✓ ' + _('No problems detected.'));
		} else {
			checkNodes = E('div', {}, checks.map(function (c) {
				var link = checkLink(c);
				return E('div', { 'class': 'wgs-check', 'style': 'border-left-color:' + (SEV[c.severity] || '#777') }, [
					badge(c.severity),
					E('div', { 'class': 'wgs-check-body' }, [
						E('div', {}, c.message),
						c.fix ? E('div', { 'class': 'wgs-check-fix' }, '→ ' + c.fix) : ''
					]),
					link || ''
				]);
			}));
		}

		body.replaceChildren(
			heroCard(d),
			fr || '',
			chainViz(d),
			E('h4', _('Failover tunnels')), E('table', { 'class': 'table' }, epRows),
			E('h4', _('Lists')), E('table', { 'class': 'table' }, listRows),
			E('h4', _('Diagnostics')), checkNodes
		);
	}

	function refresh() {
		return fs.exec('/usr/local/sbin/wg-split-doctor', [ '--json' ]).then(function (res) {
			try {
				render(JSON.parse(res.stdout || '{}'));
			} catch (e) {
				body.replaceChildren(E('pre', { 'style': 'white-space:pre-wrap' },
					_('Could not parse diagnostics:') + '\n' + ((res.stdout || res.stderr || String(e)))));
			}
		}).catch(function (e) {
			body.replaceChildren(E('em', { 'style': 'color:' + SEV.FAIL }, _('Diagnostics failed: ') + e));
		});
	}

	// One action button that runs a command, toasts, then re-runs diagnostics.
	function actionBtn(label, cls, path, args, confirmMsg, toast) {
		return E('button', {
			'class': 'btn cbi-button ' + cls,
			'click': ui.createHandlerFn(this, function () {
				if (confirmMsg && !confirm(confirmMsg)) return;
				return fs.exec(path, args || []).then(function (res) {
					ui.addNotification(null, E('p', toast || label), (res.code === 0 ? 'info' : 'warning'));
					return refresh();
				}).catch(function (e) {
					ui.addNotification(null, E('p', label + ': ' + e), 'error');
				});
			})
		}, label);
	}

	// Live auto-refresh: poll the doctor on a fixed cadence so the panel reflects
	// failover transitions without a manual click. Toggle keeps it cheap on slow
	// boxes / when the operator wants a frozen snapshot to read.
	var POLL_S = 8;
	var liveLabel = E('span', {}, _('Live'));
	var liveDot = E('span', { 'class': 'wgs-dot' });
	function setLive(on) {
		liveOn = on;
		liveDot.className = 'wgs-dot' + (on ? '' : ' wgs-dot-off');
		liveLabel.textContent = on ? _('Live (every %ds)').format(POLL_S) : _('Paused');
		if (on) { poll.add(refresh, POLL_S); poll.start(); } else poll.remove(refresh);
	}
	var liveToggle = E('span', {
		'class': 'wgs-live', 'style': 'cursor:pointer',
		'click': function () { setLive(!liveOn); }
	}, [ liveDot, liveLabel ]);

	var diagBtn = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, function () { return refresh(); })
	}, _('Refresh now'));

	var actions = E('div', { 'class': 'wgs-toolbar' }, [
		diagBtn,
		actionBtn(_('Apply'), 'cbi-button-apply', '/usr/local/sbin/wg-split-apply', [], null, _('Configuration applied')),
		actionBtn(_('Restart service'), 'cbi-button-reset', '/etc/init.d/wg-split', [ 'restart' ], null, _('Service restarted')),
		actionBtn(_('Refresh ipsum'), 'cbi-button-neutral', '/usr/local/sbin/wg-split-update-ipsum', [], null, _('ipsum refreshed')),
		actionBtn(_('Refresh ru/cn'), 'cbi-button-neutral', '/usr/local/sbin/wg-split-update-ru', [], null, _('ru/cn refreshed')),
		actionBtn(_('Refresh domains'), 'cbi-button-neutral', '/usr/local/sbin/wg-split-update-domains', [], null, _('domains refreshed')),
		actionBtn(_('Emergency disable'), 'cbi-button-remove', '/usr/local/sbin/wg-split-disable', [],
			_('Disable split routing now? All LAN traffic will exit via WAN until the service re-enables it (or you stop it).'),
			_('Split routing disabled')),
		E('span', { 'class': 'wgs-spacer' }),
		liveToggle
	]);

	// initial paint + start the poll
	refresh();
	setLive(true);

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Status & diagnostics')),
		actions,
		body
	]);
}

return view.extend({
	load: function () {
		return network.getNetworks();
	},

	render: function (networks) {
		var wgIfaces = (networks || []).filter(function (n) {
			var p = n.getProtocol();
			return p === 'amneziawg' || p === 'wireguard';
		}).map(function (n) { return n.getName(); });

		var m, s, o;

		m = new form.Map('wg-split', _('wg-split'),
			_('Local split-tunnel: policy-route LAN traffic over priority-ordered ' +
			  'WireGuard/AmneziaWG tunnels, with downloaded IP/domain lists and optional ' +
			  'zapret DPI-bypass. Create the tunnel interfaces normally under ' +
			  'Network → Interfaces, then list them below by priority.'));

		// ---- global options, grouped into native LuCI tabs (one card, three tabs:
		// General / Lists / Manual) instead of three stacked sections — cleaner and
		// renders as a single Argon card. ----
		s = m.section(form.NamedSection, 'global', 'wg-split');
		s.addremove = false;
		s.tab('general', _('General'));
		s.tab('lists',   _('Lists'));
		s.tab('manual',  _('Manual entries'));

		o = s.taboption('general', form.ListValue, 'mode', _('Routing mode'));
		o.value('blocklist', _('blocklist — only listed/ipsum IPs ride the VPN'));
		o.value('full', _('full — default via VPN, direct list = exceptions'));
		o.value('split', _('split — only explicit VPN lists ride the VPN'));
		o.default = 'blocklist';

		o = s.taboption('general', form.Value, 'interval', _('Failover interval'),
			_('Seconds between health/failover checks.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';

		o = s.taboption('general', form.Flag, 'killswitch', _('Kill switch'),
			_('Drop policy-VPN traffic when every tunnel is down instead of leaking to WAN.'));

		o = s.taboption('general', form.Value, 'lan_iface', _('LAN interface'));
		o.placeholder = 'br-lan';
		o = s.taboption('general', form.Value, 'lan_cidr', _('LAN subnet (CIDR)'));
		o.datatype = 'cidr4';
		o.placeholder = '192.168.1.0/24';

		o = s.taboption('general', form.DynamicList, 'health_target', _('Health ping targets'),
			_('Pinged through each tunnel to test it (any reply = healthy).'));
		o.datatype = 'ipaddr';
		o = s.taboption('general', form.Value, 'health_url', _('WAN health URL'),
			_('curled over WAN to decide the zapret vs plain-WAN fallback rung.'));
		o.placeholder = 'https://1.1.1.1/cdn-cgi/trace';

		o = s.taboption('lists', form.Flag, 'ipsum_enabled', _('Enable ipsum (VPN IP list)'));
		o.default = '1';
		o = s.taboption('lists', form.Value, 'ipsum_url', _('ipsum list URL'));
		o.depends('ipsum_enabled', '1');

		o = s.taboption('lists', form.Flag, 'ru_enabled', _('Enable ru/cn direct list'));
		o.default = '1';
		o = s.taboption('lists', form.Value, 'ru_url', _('ru/cn list URL'));
		o.depends('ru_enabled', '1');

		o = s.taboption('lists', form.Value, 'vpn_domains_url', _('VPN domains list URL'),
			_('Downloaded domains tagged to the VPN at dnsmasq resolve time.'));
		o = s.taboption('lists', form.Value, 'ignore_domains_url', _('Ignore/direct domains list URL'));

		o = s.taboption('lists', form.Flag, 'zapret_enabled', _('Use zapret DPI-bypass'),
			_('Auto-skipped if zapret is not installed.'));
		o.default = '1';

		o = s.taboption('manual', form.DynamicList, 'vpn_cidr', _('VPN subnets'));
		o.datatype = 'cidr4';
		o = s.taboption('manual', form.DynamicList, 'direct_cidr', _('Direct subnets'));
		o.datatype = 'cidr4';
		o = s.taboption('manual', form.DynamicList, 'vpn_domain', _('VPN domains'));
		o = s.taboption('manual', form.DynamicList, 'direct_domain', _('Direct domains'));

		// ---- failover tunnels ----
		s = m.section(form.GridSection, 'endpoint', _('Failover tunnels'),
			_('Lowest priority number wins. Pick interfaces you created under ' +
			  'Network → Interfaces.'));
		s.addremove = true;
		s.anonymous = true;
		s.sortable = true;

		o = s.option(form.ListValue, 'iface', _('Interface'));
		if (wgIfaces.length) {
			wgIfaces.forEach(function (i) { o.value(i); });
		} else {
			o.value('', _('(no wireguard/amneziawg interfaces found)'));
		}

		o = s.option(form.Value, 'priority', _('Priority'));
		o.datatype = 'uinteger';
		o.placeholder = '1';

		// ---- per-device overrides ----
		s = m.section(form.GridSection, 'device', _('Per-device overrides'),
			_('Pin a LAN host to vpn or direct by its IP.'));
		s.addremove = true;
		s.anonymous = true;

		o = s.option(form.Value, 'ip', _('Device IP'));
		o.datatype = 'ip4addr';
		o = s.option(form.ListValue, 'mode', _('Route via'));
		o.value('vpn', _('VPN'));
		o.value('direct', _('Direct'));

		return Promise.all([ statusPanel(wgIfaces), m.render() ]).then(function (nodes) {
			return E('div', {}, nodes);
		});
	}
});
