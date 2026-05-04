import type { ExternalPluginConfig } from '@windy/interfaces';

const config: ExternalPluginConfig = {
    name: 'windy-plugin-exodussail',
    version: '1.0.1',
    icon: '⛵',
    title: 'Exodussail',
    description:
        'Live track of the sailing vessel Exodussail (Daniel Pinsky), pulled from a public Garmin inReach Mini 2 MapShare feed. Shows the full track colored by speed, the latest GPS fix, and a marker that follows the Windy time slider.',
    author: 'Amir Vadai',
    repository: 'https://github.com/amirv/exodussail',
    homepage: 'https://share.garmin.com/Exodussail',
    desktopUI: 'rhpane',
    mobileUI: 'small',
    desktopWidth: 280,
    routerPath: '/exodussail',
};

export default config;
