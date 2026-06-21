'use strict';
'require view';
'require form';
'require network';
'require fs';
'require ui';
'require poll';

function statusPanel() {
	var pre = E('pre', { 'style': 'white-space:pre-wrap;margin:0' }, _('Loading…'));

	function refresh() {
		return fs.exec('/usr/local/sbin/wg-split-status').then(function (res) {
			pre.textContent = ((res.stdout || res.stderr || '').trim()) || _('(no output)');
		}).catch(function (e) {
			pre.textContent = _('status failed: ') + e;
		});
	}

	poll.add(refresh, 5);
	refresh();

	var restartBtn = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'click': ui.createHandlerFn(this, function () {
			return fs.exec('/etc/init.d/wg-split', ['restart']).then(function () {
				ui.addNotification(null, E('p', _('wg-split restarted')), 'info');
				return refresh();
			});
		})
	}, _('Restart service'));

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', _('Service status')),
		E('div', { 'style': 'margin-bottom:.5em' }, [ restartBtn ]),
		pre
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
