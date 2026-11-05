/* lg-a1-usb-ethernet: interface do app. Roda comandos como root pelo serviço
 * do Homebrew Channel (luna://org.webosbrew.hbchannel.service/exec). */
(function () {
  'use strict';

  var TEXT = {
    pt: {
      title: 'USB Ethernet (RTL8152/RTL8153)',
      subtitle: 'Driver r8152 para LG webOS 6 · plataforma lm21u (OLED A1) · experimental',
      status: 'Situação', actions: 'Ações', log: 'Registro',
      load: 'Ativar driver agora', unload: 'Desativar driver',
      autoOn: 'Ativar ao ligar a TV', autoOff: 'Não ativar ao ligar a TV',
      refresh: 'Atualizar',
      hint: 'Teste primeiro com "Ativar driver agora". Só ligue a ativação automática depois que funcionar.',
      compat: 'Compatibilidade', kernel: 'Kernel', platform: 'Plataforma', webos: 'webOS',
      adapter: 'Adaptador', driver: 'Driver em uso', iface: 'Interface de rede',
      module: 'Driver r8152', autostart: 'Ativar ao ligar', route: 'Rota padrão',
      yes: 'sim', no: 'não', loaded: 'carregado', notLoaded: 'não carregado',
      none: 'nenhum adaptador compatível conectado', compatOk: 'compatível',
      guard: 'desligado por segurança (a TV reiniciou depois de carregar o driver)',
      noRoot: 'Não foi possível falar com o Homebrew Channel. A TV precisa estar com root.',
      running: 'Executando: ', done: 'Concluído.', failed: 'Falhou: '
    },
    en: {
      title: 'USB Ethernet (RTL8152/RTL8153)',
      subtitle: 'r8152 driver for LG webOS 6 · lm21u platform (OLED A1) · experimental',
      status: 'Status', actions: 'Actions', log: 'Log',
      load: 'Load driver now', unload: 'Unload driver',
      autoOn: 'Load at TV startup', autoOff: "Don't load at startup",
      refresh: 'Refresh',
      hint: 'Test with "Load driver now" first. Only enable startup loading once it works.',
      compat: 'Compatibility', kernel: 'Kernel', platform: 'Platform', webos: 'webOS',
      adapter: 'Adapter', driver: 'Bound driver', iface: 'Network interface',
      module: 'r8152 driver', autostart: 'Load at startup', route: 'Default route',
      yes: 'yes', no: 'no', loaded: 'loaded', notLoaded: 'not loaded',
      none: 'no supported adapter connected', compatOk: 'supported',
      guard: 'turned off for safety (the TV restarted after loading the driver)',
      noRoot: 'Could not reach Homebrew Channel. The TV must be rooted.',
      running: 'Running: ', done: 'Done.', failed: 'Failed: '
    }
  };
  var lang = (navigator.language || 'en').toLowerCase().indexOf('pt') === 0 ? 'pt' : 'en';
  var T = TEXT[lang];

  var appDir = decodeURIComponent(location.pathname).replace(/\/[^/]*$/, '');
  var script = appDir + '/bin/usbeth.sh';
  var bridges = [];
  var busy = false;
  var lastStatus = {};

  function $(id) { return document.getElementById(id); }

  function translate() {
    var els = document.querySelectorAll('[data-t]');
    for (var i = 0; i < els.length; i++) els[i].textContent = T[els[i].getAttribute('data-t')];
  }

  // Modo demonstração (fora da TV): abra index.html?demo no navegador.
  var DEMO = typeof PalmServiceBridge === 'undefined' && /[?&]demo\b/.test(location.search);
  var demoStatus = 'compat=ok\nkernel=4.4.84-899.19.koli.1\nplatform=lm21u\nwebos=6.5.3\n' +
    'adapter=0bda:8153 Realtek USB 10/100/1000 LAN\nadapter_driver=r8152\nadapter_config=1\niface=eth1\n' +
    'iface_state=up\niface_carrier=1\niface_speed=1000\niface_ip=192.168.0.50/24\nmodule=loaded\n' +
    'autostart=off\ndefault_route=default via 192.168.0.1 dev eth1\n';

  function luna(uri, params) {
    return new Promise(function (resolve, reject) {
      if (DEMO) return resolve({ stdoutString: /status/.test(params.command) ? demoStatus : 'demo\n' });
      if (typeof PalmServiceBridge === 'undefined') return reject({ errorText: T.noRoot });
      var bridge = new PalmServiceBridge();
      bridges.push(bridge); // manter referência até a resposta
      bridge.onservicecallback = function (raw) {
        bridges.splice(bridges.indexOf(bridge), 1);
        var res;
        try { res = JSON.parse(raw); } catch (e) { return reject({ errorText: String(raw) }); }
        if (res.returnValue === false) reject(res); else resolve(res);
      };
      bridge.call(uri, JSON.stringify(params));
    });
  }

  function run(arg) {
    var command = "sh '" + script + "' " + arg + ' 2>&1';
    return luna('luna://org.webosbrew.hbchannel.service/exec', { command: command })
      .then(function (r) { return r.stdoutString || ''; },
            function (e) { throw new Error((e.stdoutString || '') + (e.stderrString || '') + (e.errorText || '')); });
  }

  function appendLog(text) {
    var el = $('log');
    el.textContent = (el.textContent + text.replace(/\s+$/, '') + '\n').split('\n').slice(-14).join('\n');
  }

  function row(label, value, cls) {
    return '<tr><td>' + label + '</td><td class="' + (cls || '') + '">' + escapeHtml(value || '–') + '</td></tr>';
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; });
  }

  function render(s) {
    lastStatus = s;
    var compatOk = s.compat === 'ok';
    var ifaceText = s.iface ? s.iface + ' · ' + (s.iface_state || '?') +
      (s.iface_speed && s.iface_speed !== '-1' ? ' · ' + s.iface_speed + ' Mbit/s' : '') +
      (s.iface_ip ? ' · ' + s.iface_ip : '') : '';
    var html = '';
    html += row(T.compat, compatOk ? T.compatOk : s.compat, compatOk ? 'ok' : 'bad');
    html += row(T.platform, s.platform);
    html += row(T.kernel, s.kernel);
    html += row(T.webos, s.webos);
    html += row(T.adapter, s.adapter || T.none, s.adapter ? 'ok' : 'warn');
    html += row(T.driver, s.adapter_driver);
    html += row(T.module, s.module === 'loaded' ? T.loaded : T.notLoaded, s.module === 'loaded' ? 'ok' : '');
    html += row(T.iface, ifaceText, s.iface_carrier === '1' ? 'ok' : '');
    html += row(T.autostart, s.guard ? T.guard : (s.autostart === 'on' ? T.yes : T.no), s.guard ? 'bad' : '');
    html += row(T.route, s.default_route);
    $('status').innerHTML = html;

    $('btn-auto').textContent = s.autostart === 'on' ? T.autoOff : T.autoOn;
    $('btn-load').disabled = !compatOk || s.module === 'loaded';
    $('btn-unload').disabled = s.module !== 'loaded';
    $('btn-auto').disabled = !compatOk && s.autostart !== 'on';
    fixFocus();
  }

  function parse(text) {
    var s = {};
    text.split('\n').forEach(function (line) {
      var i = line.indexOf('=');
      if (i > 0) s[line.slice(0, i)] = line.slice(i + 1);
    });
    return s;
  }

  function refresh() {
    return run('status').then(function (out) { render(parse(out)); },
                              function (e) { appendLog(T.failed + e.message); });
  }

  function action(arg) {
    if (busy) return;
    busy = true;
    appendLog(T.running + arg);
    run(arg)
      .then(function (out) { appendLog(out || T.done); },
            function (e) { appendLog(T.failed + e.message); })
      .then(refresh)
      .then(function () { busy = false; });
  }

  // Navegação com o controle remoto (setas + OK)
  function buttons() {
    return Array.prototype.filter.call(document.querySelectorAll('button'), function (b) { return !b.disabled; });
  }
  function fixFocus() {
    var list = buttons();
    if (list.length && list.indexOf(document.activeElement) < 0) list[0].focus();
  }
  document.addEventListener('keydown', function (ev) {
    var list = buttons();
    var i = list.indexOf(document.activeElement);
    var step = { 37: -1, 39: 1, 38: -2, 40: 2 }[ev.keyCode];
    if (step && list.length) {
      list[Math.max(0, Math.min(list.length - 1, (i < 0 ? 0 : i + step)))].focus();
      ev.preventDefault();
    }
  });

  translate();
  $('btn-load').onclick = function () { action('load'); };
  $('btn-unload').onclick = function () { action('unload'); };
  $('btn-auto').onclick = function () { action(lastStatus.autostart === 'on' ? 'autostart-off' : 'autostart-on'); };
  $('btn-refresh').onclick = function () { appendLog(T.running + 'status'); refresh(); };

  refresh().then(function () { return run('log 6'); }).then(function (out) { if (out) appendLog(out); }, function () {});
  fixFocus();
})();
