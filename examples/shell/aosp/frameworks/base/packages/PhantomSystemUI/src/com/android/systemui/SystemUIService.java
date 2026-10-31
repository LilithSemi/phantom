/* Copyright 2026 Phantom UI contributors. SPDX-License-Identifier: MIT */
package com.android.systemui;

import android.app.Service;
import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.ServiceConnection;
import android.content.pm.ActivityInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.content.pm.ServiceInfo;
import android.hardware.input.InputManager;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.os.UserHandle;
import android.os.UserManager;
import android.Manifest;
import android.util.Log;
import android.graphics.PixelFormat;
import android.view.Gravity;
import android.view.InputDevice;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.WindowManager;

/** Minimal framework-facing SystemUI process for a Phantom-owned Android shell. */
public final class SystemUIService extends Service {
    private static final String TAG = "PhantomSystemUI";
    /** Public contract implemented by any Phantom-based Android system shell. */
    private static final String ACTION_SYSTEM_SHELL =
            "org.phantomui.intent.action.SYSTEM_SHELL";
    private static final String ACTION_SYSTEM =
            "org.phantomui.intent.action.SYSTEM_UI_ACTION";
    private static final String EXTRA_SYSTEM_ACTION = "action";
    private static final String EXTRA_SHELL_ACTION = "org.phantomui.extra.SHELL_ACTION";
    private static final String STATUS_BAR_SERVICE_PERMISSION =
            "android.permission.STATUS_BAR_SERVICE";
    private static final int SYSTEM_ACTION_BACK = 1;
    private static final int SYSTEM_ACTION_HOME = 2;
    private static final int SYSTEM_ACTION_MENU = 3;
    private static final int TYPE_NAVIGATION_BAR = 2019;
    private static final int GESTURE_EDGE_HEIGHT_DP = 24;
    private static final int GESTURE_DISTANCE_DP = 24;
    private static final long RECENTS_HOLD_MS = 350;
    private static final long REBIND_DELAY_MS = 1000;

    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean shellBound;
    private WindowManager windowManager;
    private GestureNavigationView gestureNavigationView;

    private final Runnable rebind = this::bindShellService;

    private final ServiceConnection shellConnection = new ServiceConnection() {
        @Override public void onServiceConnected(ComponentName name, IBinder service) {
            shellBound = true;
            Log.i(TAG, "Bound to Phantom system UI service");
        }

        @Override public void onServiceDisconnected(ComponentName name) {
            shellBound = false;
            scheduleRebind();
        }

        @Override public void onBindingDied(ComponentName name) {
            shellBound = false;
            try {
                unbindService(this);
            } catch (IllegalArgumentException ignored) {
            }
            scheduleRebind();
        }

        @Override public void onNullBinding(ComponentName name) {
            shellBound = false;
            try {
                unbindService(this);
            } catch (IllegalArgumentException ignored) {
            }
            scheduleRebind();
        }
    };

    private final BroadcastReceiver systemActionReceiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            switch (intent.getIntExtra(EXTRA_SYSTEM_ACTION, 0)) {
                case SYSTEM_ACTION_BACK -> injectKey(KeyEvent.KEYCODE_BACK);
                case SYSTEM_ACTION_HOME -> injectKey(KeyEvent.KEYCODE_HOME);
                case SYSTEM_ACTION_MENU -> openShellMenu();
                default -> Log.w(TAG, "Ignoring unknown Phantom system action");
            }
        }
    };

    @Override public void onCreate() {
        super.onCreate();
        registerReceiver(
                systemActionReceiver,
                new IntentFilter(ACTION_SYSTEM),
                STATUS_BAR_SERVICE_PERMISSION,
                handler,
                Context.RECEIVER_EXPORTED);
        windowManager = getSystemService(WindowManager.class);
        addGestureNavigation();
        bindShellService();
    }

    /**
     * Reserve only an invisible touch target at the physical bottom edge. It
     * publishes no navigation inset and draws no Android or Phantom chrome.
     */
    private void addGestureNavigation() {
        if (gestureNavigationView != null) return;
        gestureNavigationView = new GestureNavigationView(this);
        int height = Math.round(GESTURE_EDGE_HEIGHT_DP
                * getResources().getDisplayMetrics().density);
        WindowManager.LayoutParams params = new WindowManager.LayoutParams(
                WindowManager.LayoutParams.MATCH_PARENT,
                height,
                TYPE_NAVIGATION_BAR,
                WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
                        | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
                PixelFormat.TRANSLUCENT);
        params.gravity = Gravity.BOTTOM;
        params.setFitInsetsTypes(0);
        params.setTitle("Phantom navigation gestures");
        windowManager.addView(gestureNavigationView, params);
    }

    private void bindShellService() {
        handler.removeCallbacks(rebind);
        if (shellBound) return;
        if (!getSystemService(UserManager.class).isUserUnlocked(UserHandle.SYSTEM)) {
            scheduleRebind();
            return;
        }
        Intent shellService = resolveActiveShellService();
        if (shellService == null) {
            scheduleRebind();
            return;
        }
        try {
            shellBound = bindServiceAsUser(
                    shellService,
                    shellConnection,
                    Context.BIND_AUTO_CREATE | Context.BIND_IMPORTANT,
                    UserHandle.SYSTEM);
        } catch (RuntimeException exception) {
            Log.w(TAG, "Phantom system UI service is not ready", exception);
            shellBound = false;
        }
        if (!shellBound) scheduleRebind();
    }

    /**
     * Select the system-shell service belonging to the current HOME package.
     * This keeps the framework bridge independent of Genesis or any future DE.
     */
    private Intent resolveActiveShellService() {
        PackageManager packages = getPackageManager();
        int matchDirectBoot = PackageManager.MATCH_DIRECT_BOOT_AWARE
                | PackageManager.MATCH_DIRECT_BOOT_UNAWARE;
        Intent homeIntent = new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME);
        ResolveInfo home = packages.resolveActivity(
                homeIntent, PackageManager.MATCH_DEFAULT_ONLY | matchDirectBoot);
        ActivityInfo activity = home == null ? null : home.activityInfo;
        if (activity == null || activity.packageName == null) return null;
        prepareShellPackage(activity.packageName);

        Intent contract = new Intent(ACTION_SYSTEM_SHELL).setPackage(activity.packageName);
        ResolveInfo resolved = packages.resolveService(contract, matchDirectBoot);
        ServiceInfo service = resolved == null ? null : resolved.serviceInfo;
        if (service == null || service.packageName == null || service.name == null) return null;
        if (packages.checkPermission(STATUS_BAR_SERVICE_PERMISSION, service.packageName)
                != PackageManager.PERMISSION_GRANTED) {
            Log.e(TAG, "Active HOME does not hold STATUS_BAR_SERVICE: " + service.packageName);
            return null;
        }
        return new Intent(ACTION_SYSTEM_SHELL).setComponent(
                new ComponentName(service.packageName, service.name));
    }

    private void prepareShellPackage(String packageName) {
        PackageManager packages = getPackageManager();
        for (String permission : new String[] {
                Manifest.permission.BLUETOOTH_CONNECT,
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.NEARBY_WIFI_DEVICES,
                Manifest.permission.ACCESS_FINE_LOCATION,
                Manifest.permission.READ_PHONE_STATE,
                Manifest.permission.POST_NOTIFICATIONS
        }) {
            try {
                packages.grantRuntimePermission(packageName, permission, UserHandle.SYSTEM);
            } catch (RuntimeException ignored) {
                // A shell only receives permissions it actually declares.
            }
        }

        Intent contract = new Intent("android.service.notification.NotificationListenerService")
                .setPackage(packageName);
        for (ResolveInfo resolved : packages.queryIntentServices(contract,
                PackageManager.MATCH_DIRECT_BOOT_AWARE | PackageManager.MATCH_DIRECT_BOOT_UNAWARE)) {
            ServiceInfo listener = resolved.serviceInfo;
            if (listener == null || listener.name == null) continue;
            if (!Manifest.permission.BIND_NOTIFICATION_LISTENER_SERVICE.equals(listener.permission)) continue;
            try {
                getSystemService(NotificationManager.class).setNotificationListenerAccessGrantedForUser(
                        new ComponentName(listener.packageName, listener.name), UserHandle.USER_SYSTEM, true);
            } catch (RuntimeException exception) {
                Log.w(TAG, "Could not grant notification access to active shell", exception);
            }
        }
    }

    private void scheduleRebind() {
        handler.removeCallbacks(rebind);
        handler.postDelayed(rebind, REBIND_DELAY_MS);
    }

    private void injectKey(int keyCode) {
        InputManager inputManager = getSystemService(InputManager.class);
        long now = SystemClock.uptimeMillis();
        for (int action : new int[] {KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP}) {
            KeyEvent event = new KeyEvent(
                    now,
                    now,
                    action,
                    keyCode,
                    0,
                    0,
                    KeyCharacterMap.VIRTUAL_KEYBOARD,
                    0,
                    KeyEvent.FLAG_FROM_SYSTEM,
                    InputDevice.SOURCE_KEYBOARD);
            inputManager.injectInputEvent(event, InputManager.INJECT_INPUT_EVENT_MODE_ASYNC);
        }
    }

    private void openShellMenu() {
        Intent home = new Intent(Intent.ACTION_MAIN)
                .addCategory(Intent.CATEGORY_HOME)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                        | Intent.FLAG_ACTIVITY_SINGLE_TOP
                        | Intent.FLAG_ACTIVITY_CLEAR_TOP)
                .putExtra(EXTRA_SHELL_ACTION, 1);
        startActivityAsUser(home, UserHandle.SYSTEM);
    }

    private final class GestureNavigationView extends View {
        private float downX;
        private float downY;
        private long downTime;

        GestureNavigationView(Context context) {
            super(context);
            setBackgroundColor(android.graphics.Color.TRANSPARENT);
        }

        @Override public boolean onTouchEvent(MotionEvent event) {
            if (event.getActionMasked() == MotionEvent.ACTION_DOWN) {
                downX = event.getX();
                downY = event.getY();
                downTime = event.getEventTime();
                return true;
            }
            if (event.getActionMasked() != MotionEvent.ACTION_UP) {
                return event.getActionMasked() != MotionEvent.ACTION_CANCEL;
            }
            float dx = event.getX() - downX;
            float dy = event.getY() - downY;
            float distance = GESTURE_DISTANCE_DP * getResources().getDisplayMetrics().density;
            if (Math.abs(dx) >= distance && Math.abs(dx) > Math.abs(dy)) {
                injectKey(KeyEvent.KEYCODE_BACK);
            } else if (dy <= -distance) {
                if (event.getEventTime() - downTime >= RECENTS_HOLD_MS) {
                    openShellMenu();
                } else {
                    injectKey(KeyEvent.KEYCODE_HOME);
                }
            }
            return true;
        }
    }

    @Override public int onStartCommand(Intent intent, int flags, int startId) {
        bindShellService();
        return START_STICKY;
    }

    @Override public void onDestroy() {
        handler.removeCallbacks(rebind);
        unregisterReceiver(systemActionReceiver);
        if (gestureNavigationView != null) windowManager.removeView(gestureNavigationView);
        gestureNavigationView = null;
        if (shellBound) unbindService(shellConnection);
        shellBound = false;
        super.onDestroy();
    }

    @Override public IBinder onBind(Intent intent) {
        return null;
    }
}
