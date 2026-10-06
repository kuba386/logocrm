/**
 * Имя куки с токеном приглашения. Живёт отдельным модулем: файл с 'use server'
 * может экспортировать только async-функции.
 */
export const INVITE_COOKIE = 'logocrm_invite_token'

/**
 * Причина неудачного принятия из /auth/callback для страницы приглашения —
 * httpOnly-кука на 2 минуты, а не ?error= в адресе: иначе по ссылке с
 * настоящим токеном на нашем домене можно было бы показать любой текст.
 */
export const INVITE_ERROR_COOKIE = 'logocrm_invite_error'
