'use client'

import { useEffect, useRef, type CSSProperties } from 'react'
import m from './landing-motion.module.css'

/**
 * 15-секундный ролик для лендинга: кинетическая типографика, перетекающая
 * форма, 3D-карточки и бесшовный цикл (кадр 15 с совпадает с кадром 0 с —
 * точка, из которой всё начинается). Только CSS-анимации и SVG: ни видео,
 * ни библиотек, чёткость на любом экране, вес — килобайты.
 *
 * Сцены (по 3 с): «Каждый звук» → «Расписание без накладок» → «Абонементы
 * и долги — сами» → «Отчёт родителю в Telegram» → LogoCRM.
 *
 * Вне экрана анимация на паузе (IntersectionObserver), при
 * prefers-reduced-motion — статичный кадр с логотипом.
 */

function Kinetic({ text, className }: { text: string; className: string }) {
  return (
    <span className={className}>
      {Array.from(text).map((ch, i) => (
        <span key={i} className={m.ch} style={{ '--i': i } as CSSProperties}>
          {ch === ' ' ? ' ' : ch}
        </span>
      ))}
    </span>
  )
}

const CARDS = [
  { time: '09:00', who: 'Айбек', sound: 'Р' },
  { time: '10:00', who: 'Алия', sound: 'Ш' },
  { time: '11:00', who: 'Тимур', sound: 'Л' },
  { time: '12:00', who: 'Мира', sound: 'С' },
]

// Разлёт букв логотипа перед сборкой — детерминированно, без Math.random,
// чтобы серверный и клиентский рендер совпадали.
const WORDMARK = Array.from('LogoCRM').map((ch, i) => ({
  ch,
  dx: [-38, -22, -6, 9, 24, 36, 48][i],
  dy: [-24, 26, -30, 22, -18, 28, -26][i],
  rz: [-40, 25, -15, 35, -30, 20, -45][i],
}))

export function LandingMotion() {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el || typeof IntersectionObserver === 'undefined') return
    const io = new IntersectionObserver(
      ([entry]) => {
        el.dataset.paused = entry?.isIntersecting ? 'false' : 'true'
      },
      { threshold: 0.15 },
    )
    io.observe(el)
    return () => io.disconnect()
  }, [])

  return (
    <figure className={m.frame}>
      <div
        ref={ref}
        className={m.stage}
        role="img"
        aria-label="Ролик о LogoCRM: путь каждого звука, расписание без накладок, абонементы и долги, отчёты родителям в Telegram"
      >
        <div className={m.paper} aria-hidden="true" />
        <div className={m.margin} aria-hidden="true" />
        <div className={m.blob} aria-hidden="true" />

        <div aria-hidden="true">
          {/* 0–3 с: звук */}
          <span className={m.glyph}>Р</span>
          <svg className={m.wave} viewBox="0 0 400 80" preserveAspectRatio="none">
            <path d="M0 40 C 25 10, 45 70, 70 40 S 115 5, 140 40 S 185 75, 210 40 S 255 12, 280 40 S 325 68, 350 40 S 385 25, 400 40" />
          </svg>
          <Kinetic text="Каждый звук" className={`${m.title} ${m.sceneA}`} />
          <Kinetic text="на своём этапе" className={`${m.sub} ${m.sceneA}`} />

          {/* 3–6 с: расписание */}
          <div className={m.deck}>
            {CARDS.map((card, i) => (
              <div key={card.time} className={m.card} style={{ '--i': i } as CSSProperties}>
                <span className={m.cardTime}>{card.time}</span>
                <span className={m.cardWho}>{card.who}</span>
                <span className={m.cardSound}>{card.sound}</span>
              </div>
            ))}
          </div>
          <Kinetic text="Расписание" className={`${m.title} ${m.sceneB}`} />
          <Kinetic text="без накладок" className={`${m.sub} ${m.sceneB}`} />

          {/* 6–9 с: абонементы */}
          <div className={m.ringWrap}>
            <svg className={m.ring} viewBox="0 0 100 100">
              <circle className={m.ringTrack} cx="50" cy="50" r="40" />
              <circle className={m.ringFill} cx="50" cy="50" r="40" />
            </svg>
            <span className={m.counter}>
              <span className={m.digits}>
                <span>8</span>
                <span>7</span>
                <span>6</span>
              </span>
            </span>
            <span className={m.counterLabel}>занятий осталось</span>
          </div>
          <Kinetic text="Абонементы" className={`${m.title} ${m.sceneC}`} />
          <Kinetic text="и долги — сами" className={`${m.sub} ${m.sceneC}`} />

          {/* 9–12 с: отчёт родителю */}
          <div className={m.track}>
            {Array.from({ length: 7 }, (_, i) => (
              <span key={i} className={i < 4 ? m.segDone : m.seg} style={{ '--i': i } as CSSProperties} />
            ))}
          </div>
          <div className={m.bubble}>
            <svg className={m.plane} viewBox="0 0 24 24">
              <path d="M2 11.5 21 3l-3.5 18-6-5-3 3v-5L19 6 7.5 13z" />
            </svg>
            <span>
              Айбек: звук «Р» — <b>в словах</b>
            </span>
          </div>
          <Kinetic text="Отчёт родителю" className={`${m.title} ${m.sceneD}`} />
          <Kinetic text="в Telegram" className={`${m.sub} ${m.sceneD}`} />

          {/* 12–15 с: логотип */}
          <span className={m.wordmark}>
            {WORDMARK.map((l, i) => (
              <span
                key={i}
                className={m.wmCh}
                style={{ '--i': i, '--dx': `${l.dx}cqw`, '--dy': `${l.dy}cqw`, '--rz': `${l.rz}deg` } as CSSProperties}
              >
                {l.ch}
              </span>
            ))}
          </span>
          <span className={m.tagline}>вся работа центра — в одной программе</span>
        </div>
      </div>
    </figure>
  )
}
