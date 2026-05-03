<section class="plugin__content">
    <div
        class="plugin__title plugin__title--chevron-back"
        on:click={() => bcast.emit('rqstOpen', 'menu')}
    >
        {title}
    </div>

    <div class="header mb-15">
        <div class="size-l">Exodussail</div>
        <div class="size-xs muted">Daniel Pinsky · Garmin inReach Mini 2</div>
    </div>

    {#if loading && !data}
        <div class="muted">Loading track…</div>
    {:else if error}
        <div class="error">Error: {error}</div>
        <div class="mt-10">
            <button class="button button--variant-orange size-s" on:click={refresh}>
                Retry
            </button>
        </div>
    {:else if latest}
        <div class="latest mb-15">
            <div><strong>Last fix:</strong> {relativeTime}</div>
            <div class="size-xs muted">{latest.time}</div>
            <div class="size-xs">
                Speed: {latest.velocity_kmh.toFixed(1)} km/h ({(latest.velocity_kmh / 1.852).toFixed(1)} kn)
            </div>
            <div class="size-xs">Course: {Math.round(latest.course_deg)}°</div>
            {#if !latest.valid_gps_fix}
                <div class="size-xs error">GPS fix invalid</div>
            {/if}
        </div>

        <div class="stats mb-15 size-xs">
            <div>Points: {pointCount.toLocaleString()}</div>
            <div>Distance: {totalKm.toFixed(0)} km · {(totalKm / 1.852).toFixed(0)} nm</div>
            <div>Max speed: {maxKmh.toFixed(1)} km/h</div>
        </div>

        <div class="legend mb-15">
            <div class="size-xs muted mb-5">Speed (km/h)</div>
            <div class="legend__bar"></div>
            <div class="legend__ticks size-xs muted">
                <span>0</span>
                <span>{(SPEED_MAX_KMH / 2).toFixed(0)}</span>
                <span>{SPEED_MAX_KMH}+</span>
            </div>
        </div>

        <div class="slider mb-15 size-xs">
            <div class="muted mb-5">Time slider position</div>
            {#if sliderInfo}
                <div>{sliderInfo.timeUtc}</div>
                <div>{formatLatLon(sliderInfo.lat, sliderInfo.lon)}</div>
                {#if sliderInfo.kmh !== null}
                    <div>~ {sliderInfo.kmh.toFixed(1)} km/h</div>
                {/if}
            {:else}
                <div class="muted">(slider outside track range)</div>
            {/if}
        </div>

        <div class="buttons mb-15">
            <button class="button size-s" on:click={refresh}>Refresh</button>
            <button class="button size-s" on:click={zoomToTrack}>Fit track</button>
            <button class="button size-s" on:click={zoomToLatest}>Latest</button>
        </div>

        <div class="size-xs muted">
            Source: GitHub gist · fetched {fetchedRelative}
        </div>
    {/if}
</section>

<script lang="ts">
    import bcast from '@windy/broadcast';
    import { map } from '@windy/map';
    import store from '@windy/store';
    import { onDestroy, onMount } from 'svelte';

    import config from './pluginConfig';

    interface LatestProps {
        time: string;
        velocity_kmh: number;
        course_deg: number;
        valid_gps_fix: boolean;
        elevation_m: number;
    }

    interface SliderInfo {
        timeUtc: string;
        lat: number;
        lon: number;
        kmh: number | null;
    }

    const { title } = config;

    const GIST_ID = '3714035ad05499b2c3867405eac89d55';
    const GEOJSON_URL =
        `https://gist.githubusercontent.com/amirv/${GIST_ID}/raw/exodussail.geojson`;
    const REFRESH_MS = 5 * 60 * 1000;
    const SPEED_MAX_KMH = 20;
    const SPEED_BIN_KMH = 2;

    let segmentLayers: L.Polyline[] = [];
    let marker: L.Marker | null = null;
    let timeMarker: L.CircleMarker | null = null;

    let data: GeoJSON.FeatureCollection | null = null;
    let loading = false;
    let error: string | null = null;
    let fetchedAt = 0;
    let now = Date.now();

    let latest: LatestProps | null = null;
    let pointCount = 0;
    let totalKm = 0;
    let maxKmh = 0;

    let trackCoords: [number, number][] = [];
    let trackTimesMs: number[] = [];
    let segmentSpeedsKmh: number[] = [];
    let trackBounds: L.LatLngBounds | null = null;

    let sliderInfo: SliderInfo | null = null;

    let refreshTimer: ReturnType<typeof setInterval> | null = null;
    let tickTimer: ReturnType<typeof setInterval> | null = null;
    let timestampHandler: ((t: number) => void) | null = null;

    $: relativeTime = latest ? formatRelative(now - new Date(latest.time).getTime()) : '';
    $: fetchedRelative = fetchedAt ? formatRelative(now - fetchedAt) : '';

    const formatRelative = (ms: number): string => {
        const s = Math.max(0, Math.round(ms / 1000));
        if (s < 60) return `${s}s ago`;
        const m = Math.round(s / 60);
        if (m < 60) return `${m} min ago`;
        const h = Math.round(m / 60);
        if (h < 24) return `${h}h ago`;
        return `${Math.round(h / 24)}d ago`;
    };

    const formatLatLon = (lat: number, lon: number): string => {
        const ns = lat >= 0 ? 'N' : 'S';
        const ew = lon >= 0 ? 'E' : 'W';
        return `${Math.abs(lat).toFixed(3)}°${ns}, ${Math.abs(lon).toFixed(3)}°${ew}`;
    };

    const haversineKm = (
        lat1: number, lon1: number,
        lat2: number, lon2: number,
    ): number => {
        const R = 6371;
        const toRad = (x: number) => (x * Math.PI) / 180;
        const dLat = toRad(lat2 - lat1);
        const dLon = toRad(lon2 - lon1);
        const a =
            Math.sin(dLat / 2) ** 2 +
            Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
        return 2 * R * Math.asin(Math.sqrt(a));
    };

    // Cool→hot ramp, 0 km/h = blue (240°), SPEED_MAX_KMH = red (0°).
    const speedColor = (kmh: number): string => {
        const t = Math.min(1, Math.max(0, kmh / SPEED_MAX_KMH));
        const hue = 240 - 240 * t;
        return `hsl(${hue}, 90%, 50%)`;
    };

    const speedBin = (kmh: number): number => {
        const maxBin = Math.floor(SPEED_MAX_KMH / SPEED_BIN_KMH);
        return Math.min(maxBin, Math.floor(kmh / SPEED_BIN_KMH));
    };

    const buildSegments = (
        coords: [number, number][],
        speeds: number[],
    ): void => {
        // Group consecutive segments that fall in the same speed bin into one
        // polyline, so we end up with ~100s of layers, not ~5,600.
        let curBin = -1;
        let chunk: [number, number][] = [];

        const flush = () => {
            if (chunk.length < 2 || curBin < 0) return;
            const midSpeed = curBin * SPEED_BIN_KMH + SPEED_BIN_KMH / 2;
            const layer = new L.Polyline(chunk as L.LatLngExpression[], {
                color: speedColor(midSpeed),
                weight: 3,
                opacity: 0.95,
            }).addTo(map);
            segmentLayers.push(layer);
        };

        for (let i = 1; i < coords.length; i++) {
            const v = speeds[i - 1];
            const bin = speedBin(v);
            if (bin !== curBin) {
                flush();
                // Start the new chunk at the prior point so the line stays
                // continuous across bin boundaries.
                chunk = [coords[i - 1]];
                curBin = bin;
            }
            chunk.push(coords[i]);
        }
        flush();
    };

    const renderOnMap = (): void => {
        clearLayers();
        if (!data?.features) return;

        const line = data.features.find(
            (f): f is GeoJSON.Feature<GeoJSON.LineString> =>
                f.geometry?.type === 'LineString',
        );
        const latestFeature = data.features.find(
            (f): f is GeoJSON.Feature<GeoJSON.Point> =>
                f.geometry?.type === 'Point' && !!f.properties?.is_latest,
        );

        if (line) {
            const coords = line.geometry.coordinates as [number, number, number?][];
            const times = (line.properties?.coordTimes ?? []) as string[];

            trackCoords = coords.map(([lon, lat]) => [lat, lon]);
            trackTimesMs = times.map(t => new Date(t).getTime());
            segmentSpeedsKmh = [];

            let dist = 0;
            let maxV = 0;
            for (let i = 1; i < coords.length; i++) {
                const [lon1, lat1] = coords[i - 1];
                const [lon2, lat2] = coords[i];
                const seg = haversineKm(lat1, lon1, lat2, lon2);
                dist += seg;
                const dtH = (trackTimesMs[i] - trackTimesMs[i - 1]) / 3_600_000;
                const v = dtH > 0 ? seg / dtH : 0;
                segmentSpeedsKmh.push(v);
                if (v > maxV) maxV = v;
            }

            pointCount = (line.properties?.point_count as number) ?? coords.length;
            totalKm = dist;
            maxKmh = maxV;
            trackBounds = L.latLngBounds(trackCoords as L.LatLngExpression[]);

            buildSegments(trackCoords, segmentSpeedsKmh);
        }

        if (latestFeature) {
            const [lon, lat] = latestFeature.geometry.coordinates;
            const props = latestFeature.properties as unknown as LatestProps;
            latest = props;
            marker = new L.Marker([lat, lon]).addTo(map);
            marker.bindPopup(
                `<strong>Exodussail</strong><br/>${props.time}<br/>` +
                `${props.velocity_kmh.toFixed(1)} km/h · ${Math.round(props.course_deg)}°`,
            );
        }

        // Sync time-slider marker to whatever the slider is currently showing.
        const t = store.get('timestamp');
        if (typeof t === 'number') updateTimeMarker(t);
    };

    const clearLayers = (): void => {
        for (const seg of segmentLayers) map.removeLayer(seg);
        segmentLayers = [];
        if (marker) {
            map.removeLayer(marker);
            marker = null;
        }
        if (timeMarker) {
            map.removeLayer(timeMarker);
            timeMarker = null;
        }
    };

    // Locate the slider time within the track and interpolate position+speed.
    // Returns null if the timestamp is outside the track's time range.
    const interpolateAtTime = (
        tMs: number,
    ): { lat: number; lon: number; kmh: number | null } | null => {
        if (trackTimesMs.length < 2) return null;
        const first = trackTimesMs[0];
        const last = trackTimesMs[trackTimesMs.length - 1];
        if (tMs < first || tMs > last) return null;

        let lo = 0;
        let hi = trackTimesMs.length - 1;
        while (hi - lo > 1) {
            const mid = (lo + hi) >> 1;
            if (trackTimesMs[mid] <= tMs) lo = mid;
            else hi = mid;
        }
        const t0 = trackTimesMs[lo];
        const t1 = trackTimesMs[hi];
        const f = t1 === t0 ? 0 : (tMs - t0) / (t1 - t0);
        const [lat0, lon0] = trackCoords[lo];
        const [lat1, lon1] = trackCoords[hi];
        const lat = lat0 + f * (lat1 - lat0);
        const lon = lon0 + f * (lon1 - lon0);
        const kmh = lo < segmentSpeedsKmh.length ? segmentSpeedsKmh[lo] : null;
        return { lat, lon, kmh };
    };

    const updateTimeMarker = (tMs: number): void => {
        const pos = interpolateAtTime(tMs);
        if (!pos) {
            if (timeMarker) {
                map.removeLayer(timeMarker);
                timeMarker = null;
            }
            sliderInfo = null;
            return;
        }
        const latlng: [number, number] = [pos.lat, pos.lon];
        if (!timeMarker) {
            timeMarker = new L.CircleMarker(latlng, {
                radius: 7,
                color: '#ffffff',
                weight: 2,
                fillColor: '#1ec8ff',
                fillOpacity: 1,
            }).addTo(map);
        } else {
            timeMarker.setLatLng(latlng);
        }
        sliderInfo = {
            timeUtc: new Date(tMs).toISOString().replace('.000', ''),
            lat: pos.lat,
            lon: pos.lon,
            kmh: pos.kmh,
        };
    };

    const load = async (busted = false): Promise<void> => {
        loading = true;
        error = null;
        try {
            const url = busted ? `${GEOJSON_URL}?t=${Date.now()}` : GEOJSON_URL;
            const r = await fetch(url);
            if (!r.ok) throw new Error(`HTTP ${r.status}`);
            data = (await r.json()) as GeoJSON.FeatureCollection;
            fetchedAt = Date.now();
            now = fetchedAt;
            renderOnMap();
        } catch (e) {
            error = e instanceof Error ? e.message : String(e);
        } finally {
            loading = false;
        }
    };

    const refresh = (): void => {
        void load(true);
    };

    const zoomToTrack = (): void => {
        if (trackBounds) map.fitBounds(trackBounds, { padding: [40, 40] });
    };

    const zoomToLatest = (): void => {
        if (marker) {
            map.setView(marker.getLatLng(), 8);
            marker.openPopup();
        }
    };

    export const onopen = (): void => {
        void load(false).then(() => {
            zoomToTrack();
        });
        refreshTimer = setInterval(() => void load(true), REFRESH_MS);
        tickTimer = setInterval(() => {
            now = Date.now();
        }, 30_000);

        timestampHandler = (t: number) => updateTimeMarker(t);
        store.on('timestamp', timestampHandler);
    };

    onMount(() => {});

    onDestroy(() => {
        clearLayers();
        if (refreshTimer) clearInterval(refreshTimer);
        if (tickTimer) clearInterval(tickTimer);
        if (timestampHandler) {
            store.off('timestamp', timestampHandler);
            timestampHandler = null;
        }
    });
</script>

<style lang="less">
    .plugin__content {
        padding-top: 5px;
    }
    .header {
        line-height: 1.3;
    }
    .latest,
    .stats,
    .slider {
        line-height: 1.5;
    }
    .muted {
        opacity: 0.7;
    }
    .error {
        color: #ff5566;
    }
    .buttons {
        display: flex;
        gap: 6px;
        flex-wrap: wrap;
    }
    .legend {
        &__bar {
            height: 8px;
            border-radius: 4px;
            background: linear-gradient(
                to right,
                hsl(240, 90%, 50%),
                hsl(180, 90%, 50%),
                hsl(120, 90%, 50%),
                hsl(60, 90%, 50%),
                hsl(0, 90%, 50%)
            );
        }
        &__ticks {
            display: flex;
            justify-content: space-between;
            margin-top: 2px;
        }
    }
    .mt-10 {
        margin-top: 10px;
    }
    .mb-5 {
        margin-bottom: 5px;
    }
    .mb-15 {
        margin-bottom: 15px;
    }
</style>
