import Gio from 'gi://Gio';
import GLib from 'gi://GLib';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'io.github.omerfaruknehir.AsusA14';
const OBJECT_PATH = '/io/github/omerfaruknehir/AsusA14';
const NATIVE_UI_MARKER = '/usr/share/asus-zenbook-a14-ec/native-gnome-five-profile';
const HID_SYSFS_ROOT = '/sys/bus/hid/devices';
const FNLOCK_POLL_MS = 200;

const ProfileIface = `
<node>
  <interface name="io.github.omerfaruknehir.AsusA14.Profile1">
    <method name="GetProfile"><arg type="s" direction="out" name="profile"/></method>
    <method name="GetProfiles"><arg type="as" direction="out" name="profiles"/></method>
    <method name="SetProfile"><arg type="s" direction="in" name="profile"/></method>
    <signal name="ProfileChanged"><arg type="s" name="profile"/></signal>
  </interface>
</node>`;

const ProfileProxy = Gio.DBusProxy.makeProxyWrapper(ProfileIface);

const PROFILE_INFO = {
    'whisper': {
        title: 'Whisper',
        icon: 'a14-power-profile-whisper-symbolic',
        description: 'Minimum disturbance',
    },
    'quiet': {
        title: 'Quiet',
        icon: 'a14-power-profile-quiet-symbolic',
        description: 'ASUS Quiet firmware mode',
    },
    'normal': {
        title: 'Normal',
        icon: 'a14-power-profile-normal-symbolic',
        description: 'ASUS Normal firmware mode',
    },
    'turbo': {
        title: 'Turbo',
        icon: 'a14-power-profile-turbo-symbolic',
        description: 'ASUS Turbo firmware mode',
    },
    'full-speed': {
        title: 'Full Speed',
        icon: 'a14-power-profile-full-speed-symbolic',
        description: 'ASUS Full Speed firmware mode',
    },
};

const PROFILE_ORDER = ['whisper', 'quiet', 'normal', 'turbo', 'full-speed'];

function showProfileOsd(profile) {
    const info = PROFILE_INFO[profile];
    if (!info)
        return;
    const gicon = new Gio.ThemedIcon({name: info.icon});
    const label = `${info.title} mode`;

    if (typeof Main.osdWindowManager.showAll === 'function')
        Main.osdWindowManager.showAll(gicon, label, null, -1);
    else
        Main.osdWindowManager.show(-1, gicon, label, null, -1);
}

function showFnLockOsd(enabled) {
    const gicon = new Gio.ThemedIcon({name: 'input-keyboard-symbolic'});
    const label = enabled ? 'Fn Lock On' : 'Fn Lock Off';

    if (typeof Main.osdWindowManager.showAll === 'function')
        Main.osdWindowManager.showAll(gicon, label, null, -1);
    else
        Main.osdWindowManager.show(-1, gicon, label, null, -1);
}

class FnLockOsdListener {
    constructor() {
        this._path = null;
        this._state = null;
        this._sourceId = GLib.timeout_add(
            GLib.PRIORITY_DEFAULT,
            FNLOCK_POLL_MS,
            () => this._poll());
        this._poll();
    }

    _findPath() {
        const root = Gio.File.new_for_path(HID_SYSFS_ROOT);
        try {
            const enumerator = root.enumerate_children(
                'standard::name', Gio.FileQueryInfoFlags.NONE, null);
            let info;
            while ((info = enumerator.next_file(null)) !== null) {
                const name = info.get_name();
                if (!name.includes('0B05:0220'))
                    continue;
                const candidate = `${HID_SYSFS_ROOT}/${name}/fn_lock`;
                if (Gio.File.new_for_path(candidate).query_exists(null)) {
                    enumerator.close(null);
                    return candidate;
                }
            }
            enumerator.close(null);
        } catch (error) {
            logError(error, 'ASUS A14 Fn-lock sysfs discovery');
        }
        return null;
    }

    _readState() {
        if (!this._path)
            this._path = this._findPath();
        if (!this._path)
            return null;

        try {
            const [ok, contents] = GLib.file_get_contents(this._path);
            if (!ok)
                return null;
            const value = new TextDecoder().decode(contents).trim();
            if (value === '-1')
                return null;
            if (value === '0')
                return false;
            if (value === '1')
                return true;
        } catch (_error) {
            // Driver reloads change the HID instance path. Rediscover it on the
            // next poll instead of spamming the GNOME Shell journal.
            this._path = null;
        }
        return null;
    }

    _poll() {
        const state = this._readState();
        if (state === null)
            return GLib.SOURCE_CONTINUE;

        if (this._state === null) {
            this._state = state;
            return GLib.SOURCE_CONTINUE;
        }

        if (state !== this._state) {
            this._state = state;
            showFnLockOsd(state);
        }
        return GLib.SOURCE_CONTINUE;
    }

    destroy() {
        if (this._sourceId)
            GLib.source_remove(this._sourceId);
        this._sourceId = 0;
        this._path = null;
        this._state = null;
    }
}

class ProfileOsdListener {
    constructor() {
        this._profile = null;
        this._profileSignal = 0;
        this._proxy = new ProfileProxy(
            Gio.DBus.system,
            BUS_NAME,
            OBJECT_PATH,
            (proxy, error) => {
                if (error) {
                    logError(error, 'ASUS A14 OSD profile service');
                    return;
                }
                proxy.GetProfileRemote((result, getError) => {
                    if (!getError)
                        this._profile = result?.[0] ?? null;
                });
                this._profileSignal = proxy.connectSignal(
                    'ProfileChanged', (_p, _sender, [profile]) => {
                        if (profile === this._profile)
                            return;
                        this._profile = profile;
                        showProfileOsd(profile);
                    });
            });
    }

    destroy() {
        if (this._proxy && this._profileSignal)
            this._proxy.disconnectSignal(this._profileSignal);
        this._profileSignal = 0;
        this._proxy = null;
    }
}

const A14ModeToggle = GObject.registerClass(
class A14ModeToggle extends QuickSettings.QuickMenuToggle {
    constructor(panelIndicator) {
        super({
            title: 'A14 Mode',
            subtitle: 'Connecting…',
            iconName: 'a14-power-profile-normal-symbolic',
            toggleMode: false,
        });

        this._panelIndicator = panelIndicator;
        this._profile = 'normal';
        this._items = new Map();
        this.menuEnabled = true;
        this.menu.setHeader('a14-power-profile-normal-symbolic', 'A14 Mode');

        this._section = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._section);
        for (const profile of PROFILE_ORDER) {
            const info = PROFILE_INFO[profile];
            const item = new PopupMenu.PopupImageMenuItem(info.title, info.icon);
            item.connect('activate', () => this._setProfile(profile));
            this._items.set(profile, item);
            this._section.addMenuItem(item);
        }
        this.menu.addSettingsAction('Power Settings', 'gnome-power-panel.desktop');

        this._proxy = new ProfileProxy(
            Gio.DBus.system,
            BUS_NAME,
            OBJECT_PATH,
            (proxy, error) => {
                if (error) {
                    logError(error, 'ASUS A14 profile service');
                    this._setUnavailable();
                    return;
                }
                this._profileSignal = proxy.connectSignal(
                    'ProfileChanged', (_p, _sender, [profile]) => {
                        const changed = profile !== this._profile;
                        this._profile = profile;
                        this._sync();
                        if (changed)
                            showProfileOsd(profile);
                    });
                this._refresh();
            });
    }

    _refresh() {
        this._proxy.GetProfileRemote((result, error) => {
            if (error) {
                logError(error, 'ASUS A14 GetProfile');
                this._setUnavailable();
                return;
            }
            this._profile = result?.[0] ?? 'normal';
            this._sync();
        });
        this._proxy.GetProfilesRemote((result, error) => {
            if (error)
                return;
            const available = new Set(result?.[0] ?? []);
            for (const [profile, item] of this._items)
                item.visible = available.has(profile);
        });
    }

    _setProfile(profile) {
        // Optimistically update the tile immediately. The ProfileChanged signal
        // from the root service remains authoritative and will reconcile it.
        const previous = this._profile;
        this._profile = profile;
        this._sync();
        this._proxy.SetProfileRemote(profile, (_result, error) => {
            if (error) {
                logError(error, `ASUS A14 SetProfile(${profile})`);
                this._profile = previous;
                this._refresh();
            }
        });
    }

    _setUnavailable() {
        this.subtitle = 'Driver service unavailable';
        this.iconName = 'dialog-warning-symbolic';
        this.menuEnabled = false;
        this._panelIndicator.visible = false;
    }

    _sync() {
        const info = PROFILE_INFO[this._profile] ?? {
            title: this._profile === 'custom' ? 'Custom' : 'Unavailable',
            icon: 'gnome-power-manager-symbolic',
        };
        this.menuEnabled = true;
        this.subtitle = info.title;
        this.iconName = info.icon;
        for (const [profile, item] of this._items) {
            item.setOrnament(profile === this._profile
                ? PopupMenu.Ornament.CHECK
                : PopupMenu.Ornament.NONE);
        }
        this.menu.setHeader(info.icon, 'A14 Mode');
        this._panelIndicator.visible = false;
    }

    destroy() {
        if (this._proxy && this._profileSignal)
            this._proxy.disconnectSignal(this._profileSignal);
        super.destroy();
    }
});

const A14Indicator = GObject.registerClass(
class A14Indicator extends QuickSettings.SystemIndicator {
    constructor() {
        super();
        this._indicator = this._addIndicator();
        this._indicator.icon_name = 'a14-power-profile-normal-symbolic';
        this._indicator.visible = false;
        this._toggle = new A14ModeToggle(this._indicator);
        this.quickSettingsItems.push(this._toggle);
    }

    destroy() {
        this.quickSettingsItems.forEach(item => item.destroy());
        super.destroy();
    }
});

export default class AsusA14ModesExtension extends Extension {
    enable() {
        // Fn-lock is not a standard GNOME power-profile signal. Watch the
        // driver's authoritative hardware state and provide our own OSD.
        this._fnLockOsdListener = new FnLockOsdListener();

        const nativeFiveProfile = Gio.File.new_for_path(NATIVE_UI_MARKER).query_exists(null);
        if (nativeFiveProfile) {
            // Patched GNOME owns the one native Power Mode tile. Keep this
            // extension loaded to present OSD for hardware state changes.
            this._osdListener = new ProfileOsdListener();
            return;
        }

        // Stock GNOME filters Quiet and Full Speed, so provide the complete A14
        // five-mode tile here. The same ProfileChanged signal also drives OSD.
        this._indicator = new A14Indicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
        this._osdListener?.destroy();
        this._osdListener = null;
        this._fnLockOsdListener?.destroy();
        this._fnLockOsdListener = null;
    }
}
