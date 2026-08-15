import Gio from 'gi://Gio';
import GObject from 'gi://GObject';

import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as QuickSettings from 'resource:///org/gnome/shell/ui/quickSettings.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const BUS_NAME = 'io.github.omerfaruknehir.AsusA14';
const OBJECT_PATH = '/io/github/omerfaruknehir/AsusA14';

const ProfileIface = `
<node>
  <interface name="io.github.omerfaruknehir.AsusA14.Profile1">
    <method name="GetProfile">
      <arg type="s" direction="out" name="profile"/>
    </method>
    <method name="GetProfiles">
      <arg type="as" direction="out" name="profiles"/>
    </method>
    <method name="GetQuietEmergency">
      <arg type="b" direction="out" name="active"/>
    </method>
    <method name="SetProfile">
      <arg type="s" direction="in" name="profile"/>
    </method>
    <signal name="ProfileChanged">
      <arg type="s" name="profile"/>
    </signal>
    <signal name="QuietEmergencyChanged">
      <arg type="b" name="active"/>
    </signal>
  </interface>
</node>`;

const ProfileProxy = Gio.DBusProxy.makeProxyWrapper(ProfileIface);

const PROFILE_INFO = {
    'quiet': {
        title: 'Quiet',
        icon: 'audio-volume-low-symbolic',
        description: 'ASUS Quiet firmware mode',
    },
    'normal': {
        title: 'Normal',
        icon: 'power-profile-balanced-symbolic',
        description: 'ASUS Normal firmware mode',
    },
    'turbo': {
        title: 'Turbo',
        icon: 'power-profile-performance-symbolic',
        description: 'ASUS Turbo firmware mode',
    },
    'full-speed': {
        title: 'Full Speed',
        icon: 'power-profile-performance-symbolic',
        description: 'ASUS Full Speed firmware mode',
    },
};

const PROFILE_ORDER = ['quiet', 'normal', 'turbo', 'full-speed'];

const A14ModeToggle = GObject.registerClass(
class A14ModeToggle extends QuickSettings.QuickMenuToggle {
    constructor(panelIndicator) {
        super({
            title: 'A14 Mode',
            subtitle: 'Connecting…',
            iconName: 'power-profile-balanced-symbolic',
            toggleMode: false,
        });

        this._panelIndicator = panelIndicator;
        this._profile = 'normal';
        this._emergency = false;
        this._items = new Map();
        this.menuEnabled = true;
        this.menu.setHeader('power-profile-balanced-symbolic', 'A14 Mode');

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
                        this._profile = profile;
                        this._sync();
                    });
                this._emergencySignal = proxy.connectSignal(
                    'QuietEmergencyChanged', (_p, _sender, [active]) => {
                        this._emergency = active;
                        this._sync();
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
        this._proxy.SetProfileRemote(profile, (_result, error) => {
            if (error) {
                logError(error, `ASUS A14 SetProfile(${profile})`);
                Main.notifyError(
                    'A14 Mode',
                    `Could not switch to ${PROFILE_INFO[profile]?.title ?? profile}`);
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
            description: '',
        };

        this.menuEnabled = true;
        this.subtitle = info.title;
        this.iconName = info.icon;

        for (const [profile, item] of this._items) {
            item.setOrnament(
                profile === this._profile
                    ? PopupMenu.Ornament.CHECK
                    : PopupMenu.Ornament.NONE);
        }

        this.menu.setHeader(info.icon, 'A14 Mode');
        this._panelIndicator.visible = false;
    }

    destroy() {
        if (this._proxy) {
            if (this._profileSignal)
                this._proxy.disconnectSignal(this._profileSignal);
            if (this._emergencySignal)
                this._proxy.disconnectSignal(this._emergencySignal);
        }
        super.destroy();
    }
});

const A14Indicator = GObject.registerClass(
class A14Indicator extends QuickSettings.SystemIndicator {
    constructor() {
        super();
        this._indicator = this._addIndicator();
        this._indicator.icon_name = 'power-profile-balanced-symbolic';
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
        this._indicator = new A14Indicator();
        Main.panel.statusArea.quickSettings.addExternalIndicator(this._indicator);
    }

    disable() {
        this._indicator?.destroy();
        this._indicator = null;
    }
}