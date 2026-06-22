'use strict';
'require view';
'require form';
'require network';
'require fs';
'require ui';

// Severity -> CSS color (matches wg-split-doctor's OK/WARN/FIXABLE/FAIL).
var SEV = {
	OK:      '#3c763d',
	WARN:    '#8a6d3b',
	FIXABLE: '#a0522d',
	FAIL:    '#a94442'
};

function badge(sev) {
	return E('span', {
		'style': 'display:inline-block;padding:.1em .5em;border-radius:.25em;color:#fff;' +
		         'font-weight:bold;background:' + (SEV[sev] || '#777')
	}, sev);
}

function yn(v) {
	return E('span', { 'style': 'color:' + (v ? SEV.OK : SEV.FAIL) }, v ? _('yes') : _('no'));
}

// Doctor is passive: per-endpoint health is handshake-derived — 'ok' (fresh) /
// 'idle' (stale, not probed). 'OK'/'FAIL' only appear if a future active probe
// is added. The daemon-confirmed live tunnel is shown as the Active path above.
function healthCell(h) {
	if (h === 'OK' || h === 'ok') return E('span', { 'style': 'color:' + SEV.OK }, h);
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

function statusPanel() {
	var body = E('div', {}, E('em', _('Loading diagnostics…')));

	function render(d) {
		var s = d.summary || {};
		var path = (s.state || _('unknown'));

		var summary = E('table', { 'class': 'table' }, [
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td', 'width': '25%' }, E('strong', _('Overall'))),
				E('td', { 'class': 'td' }, badge(d.overall || 'FAIL'))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', _('Active path'))),
				E('td', { 'class': 'td' }, path)
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', _('Mode'))),
				E('td', { 'class': 'td' }, (s.mode || '?') +
					' · ' + _('killswitch') + ' ' + (String(s.killswitch) === '1' ? _('on') : _('off')) +
					' · ' + _('failures') + ' ' + (s.fail_count != null ? s.fail_count : '?'))
			]),
			E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td' }, E('strong', _('LAN'))),
				E('td', { 'class': 'td' }, (s.lan_iface || '?') + ' → ' + (s.lan_cidr || _('(none detected)')))
			])
		]);

		// endpoints
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

		// lists
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
			checkNodes = E('p', { 'style': 'color:' + SEV.OK }, '✓ ' + _('No problems detected.'));
		} else {
			checkNodes = E('div', {}, checks.map(function (c) {
				return E('div', { 'style': 'margin:.4em 0;padding:.4em .6em;border-left:3px solid ' + (SEV[c.severity] || '#777') }, [
					badge(c.severity), ' ', E('span', {}, c.message),
					c.fix ? E('div', { 'style': 'color:#666;font-size:90%;margin-top:.2em' }, '→ ' + c.fix) : ''
				]);
			}));
		}

		body.replaceChildren(
			E('h4', _('State')), summary,
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

	var diagBtn = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, function () { return refresh(); })
	}, _('Run diagnostics'));

	var actions = E('div', { 'style': 'margin:.5em 0;display:flex;flex-wrap:wrap;gap:.4em' }, [
		diagBtn,
		actionBtn(_('Apply'), 'cbi-button-apply', '/usr/local/sbin/wg-split-apply', [], null, _('Configuration applied')),
		actionBtn(_('Restart service'), 'cbi-button-reset', '/etc/init.d/wg-split', [ 'restart' ], null, _('Service restarted')),
		actionBtn(_('Refresh ipsum'), 'cbi-button-neutral', '/usr/local/sbin/wg-split-update-ipsum', [], null, _('ipsum refreshed')),
		actionBtn(_('Refresh ru/cn'), 'cbi-button-neutral', '/usr/local/sbin/wg-split-update-ru', [], null, _('ru/cn refreshed')),
		actionBtn(_('Refresh domains'), 'cbi-button-neutral', '/usr/local/sbin/wg-split-update-domains', [], null, _('domains refreshed')),
		actionBtn(_('Emergency disable'), 'cbi-button-remove', '/usr/local/sbin/wg-split-disable', [],
			_('Disable split routing now? All LAN traffic will exit via WAN until the service re-enables it (or you stop it).'),
			_('Split routing disabled'))
	]);

	refresh();

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

		// ---- general ----
		s = m.section(form.NamedSection, 'global', 'wg-split', _('General'));
		s.addremove = false;

		o = s.option(form.ListValue, 'mode', _('Routing mode'));
		o.value('blocklist', _('blocklist — only listed/ipsum IPs ride the VPN'));
		o.value('full', _('full — default via VPN, direct list = exceptions'));
		o.value('split', _('split — only explicit VPN lists ride the VPN'));
		o.default = 'blocklist';

		o = s.option(form.Value, 'interval', _('Failover interval'),
			_('Seconds between health/failover checks.'));
		o.datatype = 'uinteger';
		o.placeholder = '180';

		o = s.option(form.Flag, 'killswitch', _('Kill switch'),
			_('Drop policy-VPN traffic when every tunnel is down instead of leaking to WAN.'));

		o = s.option(form.Value, 'lan_iface', _('LAN interface'));
		o.placeholder = 'br-lan';
		o = s.option(form.Value, 'lan_cidr', _('LAN subnet (CIDR)'));
		o.datatype = 'cidr4';
		o.placeholder = '192.168.1.0/24';

		o = s.option(form.DynamicList, 'health_target', _('Health ping targets'),
			_('Pinged through each tunnel to test it (any reply = healthy).'));
		o.datatype = 'ipaddr';
		o = s.option(form.Value, 'health_url', _('WAN health URL'),
			_('curled over WAN to decide the zapret vs plain-WAN fallback rung.'));
		o.placeholder = 'https://1.1.1.1/cdn-cgi/trace';

		// ---- lists ----
		s = m.section(form.NamedSection, 'global', 'wg-split', _('Lists'));
		s.addremove = false;

		o = s.option(form.Flag, 'ipsum_enabled', _('Enable ipsum (VPN IP list)'));
		o.default = '1';
		o = s.option(form.Value, 'ipsum_url', _('ipsum list URL'));
		o.depends('ipsum_enabled', '1');

		o = s.option(form.Flag, 'ru_enabled', _('Enable ru/cn direct list'));
		o.default = '1';
		o = s.option(form.Value, 'ru_url', _('ru/cn list URL'));
		o.depends('ru_enabled', '1');

		o = s.option(form.Value, 'vpn_domains_url', _('VPN domains list URL'),
			_('Downloaded domains tagged to the VPN at dnsmasq resolve time.'));
		o = s.option(form.Value, 'ignore_domains_url', _('Ignore/direct domains list URL'));

		o = s.option(form.Flag, 'zapret_enabled', _('Use zapret DPI-bypass'),
			_('Auto-skipped if zapret is not installed.'));
		o.default = '1';

		// ---- manual additions ----
		s = m.section(form.NamedSection, 'global', 'wg-split', _('Manual entries'));
		s.addremove = false;

		o = s.option(form.DynamicList, 'vpn_cidr', _('VPN subnets'));
		o.datatype = 'cidr4';
		o = s.option(form.DynamicList, 'direct_cidr', _('Direct subnets'));
		o.datatype = 'cidr4';
		o = s.option(form.DynamicList, 'vpn_domain', _('VPN domains'));
		o = s.option(form.DynamicList, 'direct_domain', _('Direct domains'));

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

		return Promise.all([ statusPanel(), m.render() ]).then(function (nodes) {
			return E('div', {}, nodes);
		});
	}
});
