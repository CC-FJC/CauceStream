package com.cauce.cauce_stream

import android.app.Activity
import android.os.Build
import android.os.Bundle

/**
 * Activity desechable que enciende la pantalla.
 *
 * Android 14+ ignora los wake locks de la receta clásica
 * (FULL_WAKE_LOCK | ACQUIRE_CAUSES_WAKEUP) para apps con targetSdk 34+:
 * la vía pública para despertar es LANZAR una activity con
 * setTurnScreenOn(true), como hacen las alarmas. Esta activity no
 * pinta nada: se lanza, el sistema enciende la pantalla para su
 * creación, y termina en el mismo onCreate — el kiosk que queda
 * debajo (o la web externa) reaparece ya con la pantalla encendida.
 */
class WakeActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setTurnScreenOn(true)
            setShowWhenLocked(true)
        }
        // Nada que pintar: solo existimos para que el sistema encienda
        // la pantalla al mostrarnos.
    }

    override fun onResume() {
        super.onResume()
        // El sistema aplica setTurnScreenOn al llegar aquí: cerrar en
        // onCreate se lo saltaba (la activity moría antes de que el
        // pipeline de encendido la procesara y la pantalla no despertaba).
        finish()
    }
}
