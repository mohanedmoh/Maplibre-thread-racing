/**
 * Minimal reproduction for an Android startup race in MapLibre.
 *
 * The app does one thing: it calls the offline manager during the first
 * render, which is what a real app does to configure offline storage. It calls
 * nothing else in MapLibre, renders no map, and adds no workaround (no
 * MapLibre.getInstance in MainApplication).
 *
 * On @maplibre/maplibre-react-native 10.1.5 the same calls lost a race with
 * the library's own MapLibre.getInstance, which is only posted to the UI
 * thread, and the app either crashed (MapLibreConfigurationException on
 * mqt_v_native) or deadlocked loading libmaplibre.so.
 *
 * Every step logs a `[repro]` line so a test script can tell a clean start
 * from a crash or a hang.
 */
import React, { useEffect, useState } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { OfflineManager } from '@maplibre/maplibre-react-native';

function App() {
  const [status, setStatus] = useState('offline calls pending');

  useEffect(() => {
    console.log('[repro] first effect: calling OfflineManager');
    OfflineManager.setTileCountLimit(20000);
    OfflineManager.setProgressEventThrottle(500);
    OfflineManager.setMaximumAmbientCacheSize(250 * 1024 * 1024).then(
      () => {
        console.log('[repro] offline configured');
        setStatus('offline configured');
      },
      (error: unknown) => {
        console.log(`[repro] offline rejected: ${String(error)}`);
        setStatus(`offline rejected: ${String(error)}`);
      },
    );
  }, []);

  return (
    <View style={styles.container}>
      <Text style={styles.title}>MapLibre startup repro</Text>
      <Text testID="status">{status}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, alignItems: 'center', justifyContent: 'center' },
  title: { fontSize: 20, fontWeight: '600', marginBottom: 12 },
});

export default App;
