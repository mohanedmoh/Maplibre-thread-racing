/**
 * @format
 */

import { AppRegistry } from 'react-native';
import { OfflineManager } from '@maplibre/maplibre-react-native';
import App from './App';
import { name as appName } from './app.json';

// Variant switch for the repro.
//   false: the only offline calls are in App's first effect (App.tsx).
//   true:  one more call is made here, when the bundle loads. That is the
//          earliest moment a JS app can reach the offline module.
const EARLY_CALL = false;

if (EARLY_CALL) {
  console.log('[repro] bundle load: calling OfflineManager');
  OfflineManager.setTileCountLimit(20000);
}

AppRegistry.registerComponent(appName, () => App);
