import Link from 'next/link'
import type { CSSProperties } from 'react'
import s from './landing.module.css'
import { LandingMotion } from './landing-motion'

// Этапы — сид goal_stages (0036): тот же порядок и те же названия, что видит логопед.
const STAGES = [
  'Постановка',
  'Изолированно',
  'В слогах',
  'В словах',
  'Во фразах',
  'В связной речи',
  'Дифференциация',
]

const GOALS = [
  { sound: 'Р', stage: 4 },
  { sound: 'Ш', stage: 5 },
  { sound: 'Л', stage: 1 },
]

const AUDIENCES = [
  {
    title: 'Руководителю',
    items: [
      'Расписание специалистов и кабинетов: два занятия в одно время база не запишет.',
      'Абонементы, заморозки и рассрочки. Кто сколько должен — на одной странице.',
      'Зарплата специалистов по ставкам, расходы и выручка за месяц.',
      'Отдельные права для администратора, регистратора и бухгалтера.',
    ],
  },
  {
    title: 'Логопеду',
    items: [
      'Обследование: звукопроизношение, слоговая структура, просодия, чтение и письмо.',
      'Цели по каждому звуку с этапом — от постановки до дифференциации.',
      'Голосовая заметка после занятия становится протоколом. Вы проверяете и отправляете.',
      'Домашние задания из библиотеки упражнений.',
    ],
  },
  {
    title: 'Родителю',
    items: [
      'Напоминание о занятии в Telegram и подтверждение одной кнопкой.',
      'Сколько занятий осталось по абонементу и что оплачено.',
      'Домашние задания и отчёт о прогрессе за месяц.',
      'Запись на первое занятие со страницы центра.',
    ],
  },
]

const PLANS = [
  {
    name: 'Solo',
    price: '990',
    note: 'Частная практика',
    limits: ['1 специалист', 'До 40 учеников', '30 протоколов из голосовых в месяц', '100 вопросов помощнику в месяц'],
  },
  {
    name: 'Studio',
    price: '3\u202f900',
    note: 'Пробный период — на этом тарифе',
    limits: ['До 5 специалистов', 'До 200 учеников', '200 протоколов из голосовых в месяц', '500 вопросов помощнику в месяц'],
  },
  {
    name: 'Center',
    price: '7\u202f900',
    note: 'Для большого центра',
    limits: ['Специалисты без ограничений', 'Ученики без ограничений', '1000 протоколов из голосовых в месяц', '2000 вопросов помощнику в месяц'],
  },
]

export function Landing() {
  return (
    <div className={s.page}>
      <header className={s.header}>
        <Link href="/" className={s.wordmark}>
          LogoCRM
        </Link>
        <nav className={s.nav} aria-label="Вход">
          <Link href="/login" className={s.navLink}>
            Войти
          </Link>
          <Link href="/login?mode=signup" className={s.buttonSmall}>
            Попробовать бесплатно
          </Link>
        </nav>
      </header>

      <main>
        <section className={s.hero}>
          <div className={s.heroText}>
            <h1 className={s.title}>Вся работа логопедического центра в одной программе</h1>
            <p className={s.lead}>
              Расписание без накладок, абонементы и долги, путь каждого звука и отчёты родителям в
              Telegram. Для логопедических центров и частных логопедов Кыргызстана.
            </p>
            <div className={s.actions}>
              <Link href="/login?mode=signup" className={s.button}>
                Попробовать бесплатно
              </Link>
              <span className={s.actionsNote}>14 дней без оплаты, тариф выбираете потом</span>
            </div>
          </div>

          <figure className={s.notebook} aria-labelledby="notebook-caption">
            <figcaption id="notebook-caption" className={s.notebookHead}>
              <span className={s.notebookName}>Айбек, 5 лет</span>
              <span className={s.notebookMeta}>цели на октябрь</span>
            </figcaption>
            <ul className={s.goals}>
              {GOALS.map((goal, row) => (
                <li key={goal.sound} className={s.goal}>
                  <span className={s.glyph} aria-hidden="true">
                    {goal.sound}
                  </span>
                  <div className={s.goalBody}>
                    <span className={s.goalStage}>
                      <span className={s.visuallyHidden}>Звук {goal.sound}: </span>
                      {STAGES[goal.stage - 1]}
                      <span className={s.goalStep}>
                        {' '}
                        {goal.stage} из {STAGES.length}
                      </span>
                    </span>
                    <span className={s.track} aria-hidden="true">
                      {STAGES.map((stage, i) => (
                        <span
                          key={stage}
                          className={i < goal.stage ? s.segmentDone : s.segment}
                          style={{ '--delay': `${row * 120 + i * 70}ms` } as CSSProperties}
                        />
                      ))}
                    </span>
                  </div>
                </li>
              ))}
            </ul>
            <ol className={s.stages}>
              {STAGES.map((stage) => (
                <li key={stage}>{stage}</li>
              ))}
            </ol>
          </figure>
        </section>

        <section className={s.section} aria-label="Как работает LogoCRM">
          <LandingMotion />
        </section>

        <section className={s.section} aria-labelledby="film-title">
          <h2 id="film-title" className={s.sectionTitle}>
            LogoCRM за минуту
          </h2>
          <p className={s.sectionLead}>
            Как выглядит обычный день центра: расписание, отчёт родителю из голосового, цели по звукам
            и абонементы.
          </p>
          <figure className={s.film}>
            {/* preload="none": минута видео не грузится, пока её не включили, — мобильный трафик. */}
            <div className={s.filmFrame}>
              <video
                className={s.filmVideo}
                src="/video/logocrm-60s.mp4"
                poster="/video/logocrm-60s.jpg"
                controls
                playsInline
                preload="none"
                width={1280}
                height={720}
                aria-describedby="film-caption"
              >
                <a href="/video/logocrm-60s.mp4">Открыть видео</a>
              </video>
            </div>
            <figcaption id="film-caption" className={s.filmCaption}>
              1 минута, со звуком. Расписание не даёт поставить два занятия в один кабинет · голосовое
              после занятия становится отчётом родителю · нарушенные звуки сразу становятся целями ·
              абонементы и долги считаются сами · LogoCRM ставится на телефон как приложение.
            </figcaption>
          </figure>
        </section>

        <section className={s.section} aria-labelledby="audiences-title">
          <h2 id="audiences-title" className={s.sectionTitle}>
            Каждый видит своё
          </h2>
          <p className={s.sectionLead}>
            Одна программа на весь центр. Логопед не видит зарплат, родитель — чужих детей: права
            проверяет база, а не интерфейс.
          </p>
          <div className={s.audiences}>
            {AUDIENCES.map((audience) => (
              <div key={audience.title} className={s.audience}>
                <h3 className={s.audienceTitle}>{audience.title}</h3>
                <ul className={s.ruledList}>
                  {audience.items.map((item) => (
                    <li key={item}>{item}</li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </section>

        <section className={s.section} aria-labelledby="plans-title">
          <h2 id="plans-title" className={s.sectionTitle}>
            Тарифы
          </h2>
          <p className={s.sectionLead}>
            Цена в месяц за весь центр, без доплаты за каждого сотрудника. Первые 14 дней — бесплатно.
            При оплате сразу за 6 месяцев — скидка 10%, за 12 месяцев — 20%.
          </p>
          <div className={s.plans}>
            {PLANS.map((plan) => (
              <div key={plan.name} className={s.plan}>
                <h3 className={s.planName}>{plan.name}</h3>
                <p className={s.planPrice}>
                  {plan.price}
                  <span className={s.planCurrency}> сом в месяц</span>
                </p>
                <p className={s.planNote}>{plan.note}</p>
                <ul className={s.ruledList}>
                  {plan.limits.map((limit) => (
                    <li key={limit}>{limit}</li>
                  ))}
                </ul>
              </div>
            ))}
          </div>
        </section>

        <section className={s.closing} aria-labelledby="closing-title">
          <h2 id="closing-title" className={s.closingTitle}>
            Попробуйте на своём центре
          </h2>
          <p className={s.closingLead}>
            Нужны только email, пароль и название центра. Специалистов пригласите ссылкой.
          </p>
          <Link href="/login?mode=signup" className={s.button}>
            Попробовать бесплатно
          </Link>
        </section>
      </main>

      <footer className={s.footer}>
        <span>© 2026 LogoCRM</span>
        <Link href="/login" className={s.navLink}>
          Войти
        </Link>
      </footer>
    </div>
  )
}
