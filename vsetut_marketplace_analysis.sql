/* Проект «Разработка витрины и решение ad-hoc задач»
 * Цель проекта: подготовка витрины данных маркетплейса «ВсёТут»
 * и решение четырех ad hoc задач на её основе
 * 
 * Автор: Авдеев Николай
 * Дата: 16.11.2025
 */



/* Часть 1. Разработка витрины данных
 */
	
WITH 
order_payments_agg AS (
    SELECT
        o.order_id,
        FIRST_VALUE(payment_type) OVER (PARTITION BY o.order_id ORDER BY payment_sequential) AS first_payment_type,
        MAX(CASE WHEN payment_type = 'промокод' THEN 1 ELSE 0 END) OVER (PARTITION BY o.order_id) AS promo_used,
        MAX(CASE WHEN payment_installments > 1 THEN 1 ELSE 0 END) OVER (PARTITION BY o.order_id) AS used_installments
    FROM ds_ecom.orders AS o
    LEFT JOIN ds_ecom.order_payments AS op ON o.order_id = op.order_id
),
order_reviews_agg AS (
    SELECT
        order_id,
        AVG(
            CASE 
                WHEN eor.review_score BETWEEN 1 AND 5 THEN eor.review_score
                WHEN eor.review_score BETWEEN 10 AND 50 THEN eor.review_score / 10.0
                ELSE NULL
            END
        ) AS avg_order_rating
    FROM ds_ecom.order_reviews AS eor
    GROUP BY order_id
),
order_items_agg AS (
	SELECT
		o.order_id,
		SUM(CASE WHEN o.order_status <> 'Отменено' THEN price + delivery_cost END) OVER (PARTITION BY o.order_id) AS sum_order_delivery
	FROM ds_ecom.order_items AS oi 
	LEFT JOIN ds_ecom.orders AS o ON oi.order_id = o.order_id
),
pay_rating_orders AS (
	SELECT
    	DISTINCT o.order_id,
    	o.buyer_id,
    	first_payment_type,
    	promo_used,
    	used_installments,
    	sum_order_delivery,
    	avg_order_rating
FROM ds_ecom.orders AS o
LEFT JOIN order_payments_agg AS pa ON o.order_id = pa.order_id
LEFT JOIN order_items_agg AS ia ON o.order_id = ia.order_id
LEFT JOIN order_reviews_agg AS ra ON o.order_id = ra.order_id
WHERE o.order_status IN ('Доставлено', 'Отменено')
),
top_regions AS (
	SELECT 
		region,
		COUNT(*) AS total_orders
    FROM ds_ecom.orders AS o
    JOIN ds_ecom.users AS u ON o.buyer_id = u.buyer_id
    WHERE o.order_status IN ('Доставлено', 'Отменено')
    GROUP BY region
    ORDER BY total_orders DESC
    LIMIT 3
),
final_stats AS (
	SELECT
        user_id,
        region,
        MIN(order_purchase_ts) AS first_order_ts,
        MAX(order_purchase_ts) AS last_order_ts,
        MAX(order_purchase_ts) - MIN(order_purchase_ts) AS lifetime,
        COUNT(o.order_id) AS total_orders,
        SUM(sum_order_delivery) AS total_order_costs,
        ROUND(AVG(sum_order_delivery), 2) AS avg_order_cost,
        SUM(CASE WHEN order_status = 'Отменено' THEN 1 ELSE 0 END) AS num_canceled_orders,
        COUNT(avg_order_rating) AS num_orders_with_rating,
        SUM(promo_used) AS num_orders_with_promo,
        SUM(used_installments) AS num_installment_orders,
        AVG(avg_order_rating) AS avg_order_rating,
        MAX(CASE WHEN first_payment_type = 'денежный перевод' THEN 1 ELSE 0 END) AS used_money_transfer,
        MAX(used_installments) AS used_installments,
        MAX(CASE WHEN o.order_status = 'Отменено' THEN 1 ELSE 0 END) AS used_cancel
    FROM ds_ecom.users AS u
    LEFT JOIN ds_ecom.orders AS o ON u.buyer_id = o.buyer_id 
    LEFT JOIN pay_rating_orders AS pro ON o.order_id = pro.order_id
    WHERE region IN (SELECT region FROM top_regions) AND o.order_status IN ('Доставлено', 'Отменено')
    GROUP BY user_id, region
    ORDER BY total_orders DESC, region DESC 
)
SELECT 
	user_id,
	region,
	first_order_ts,
	last_order_ts,
	lifetime,
	total_orders,
	avg_order_rating,
	num_orders_with_rating,
	num_canceled_orders,
	CASE WHEN total_orders > 0 THEN num_canceled_orders::numeric / total_orders ELSE 0 END AS canceled_orders_ratio,
	total_order_costs,
	avg_order_cost,
	num_installment_orders,
	num_orders_with_promo,
	used_money_transfer,
	used_installments,
	used_cancel
FROM final_stats;


/* Решение ad hoc задач
 */
/* Сегментация клиентской базы по истории покупок.
 * Цель: выявление ядра лояльной аудитории, расчет среднего чека по сегментам 
 * и оценка распределения пользователей для разработки стратегии удержания.
 */

SELECT
	CASE
    	WHEN total_orders = 1 THEN '1 заказ'
    	WHEN total_orders BETWEEN 2 AND 5 THEN '2–5 заказов'
    	WHEN total_orders BETWEEN 6 AND 10 THEN '6–10 заказов'
    	WHEN total_orders >= 11 THEN '11 и более заказов'
	END AS user_segment,
	COUNT(user_id) AS count_users,
	ROUND(AVG(total_orders), 2) AS avg_orders,
	ROUND(AVG(total_order_costs), 2) AS avg_order_cost
FROM ds_ecom.product_user_features
GROUP BY user_segment
ORDER BY count_users DESC;


/*
 * ВЫВОДЫ ПО СЕГМЕНТАЦИИ:
 * Анализ данных показывает, что подавляющее большинство пользователей (около 99,5%) совершают единственную покупку, что и формирует основную часть выручки 
 * компании, в то время как небольшая группа активных клиентов приносит незначительную часть прибыли за счет высокого количества заказов и их среднего чека.
 * Для увеличения общей прибыльности целесообразно сосредоточить усилия на стимулировании повторных покупок и повышении лояльности основной клиентской базы.
 */

/* 
 * Ранжирование пользователей 
 * Анализ лояльного сегмента пользователей (VIP-клиенты).
 * Цель: выявление топ-15 наиболее ценных покупателей (от 3 заказов и более)
 * на основе их среднего чека для потенциальной интеграции в премиальные программы лояльности. 
 */

SELECT
	user_id,
	region,
	total_orders,
	avg_order_cost
FROM ds_ecom.product_user_features
WHERE total_orders >= 3
ORDER BY avg_order_cost DESC
LIMIT 15


/*
 * ВЫВОДЫ ПО ЛОЯЛЬНОМУ СЕГМЕНТУ:
 * Исходя из результатов, можно сделать вывод, что среди клиентов из категории не менее 3-х заказов наибольший средний чек зафиксирован у пользователей
 * из Санкт-Петербурга и Москвы, что указывает на высокий уровень покупательской способности в этих регионах.
 * Эти активные клиенты приносят выручку за счет высоких средних чеков, что подчеркивает важность стратегий по их удержанию
 * и повышению лояльности. Для повышения общей рентабельности рекомендуется сфокусироваться на стимулировании повторных покупок у данной категории клиентов.
 */

/* 
 * Статистика по регионам. 
 * Региональная аналитика продаж и активности.
 * Цель: расчет ключевых метрик по географии присутствия для оценки эффективности рынков.
 * Оцениваются объемы заказов, средний чек, проникновение финансовых инструментов (рассрочка), 
 * эффективность промо-кампаний и доля отказов.
 */

SELECT
	region,
    COUNT(DISTINCT user_id) AS total_users,
    SUM(total_orders) AS total_orders_region,
    ROUND((CASE WHEN SUM(total_orders) > 0 THEN SUM(total_order_costs) / SUM(total_orders) ELSE 0 END), 2) AS avg_order_value,
    ROUND((CASE WHEN SUM(total_orders) > 0 THEN SUM(num_installment_orders)::numeric / SUM(total_orders) ELSE 0 END), 3) AS share_installment_orders,
    ROUND((CASE WHEN SUM(total_orders) > 0 THEN SUM(num_orders_with_promo)::numeric / SUM(total_orders) ELSE 0 END), 4) AS share_promo_orders,
    ROUND((CASE WHEN COUNT(DISTINCT user_id) > 0 THEN SUM(CASE WHEN used_cancel = 1 THEN 1 ELSE 0 END)::numeric / COUNT(DISTINCT user_id) ELSE 0
    END), 5) AS share_cancel_users
FROM ds_ecom.product_user_features
GROUP BY region;


/*
 * ВЫВОДЫ ПО РЕГИОНАМ:
 * Анализ данных показывает, что Москва занимает около 78% клиентов и 80% заказов среди рассматриваемых регионов, колоссально опережая
 * Новосибирскую область и Санкт-Петербург. Средний чек в Москве немного ниже - примерно 3 140 рублей, в то время как в других регионах он выше -
 * около 3 491–3 593 рублей. Рассрочка крайне популярна по регионам и используется более чем половине (54-55%) заказов по Санкт-Петербургу и 
 * Новосибирской области и чуть менее (48%) по Москве. Промоакции используют умеренно (3.7–4.2%), где выделяется только Санкт-Петербург с 4.2%.
 * Отмены в заказах довольно низкие (0.4–0.6%), где чуть больший процент занимает Москва, что естественно при учете кол-ва заказов. Рекомендуется
 * рассмотреть индивидуальные стратегии повышения лояльности, эффективности маркетинга и работы с возражениями клиентов по регионам с меньшей активностью,
 * для Москвы же использовать расширение предложений для увеличения базы и доходов.
 */

/* 
 * Анализ динамики привлечения и активности новых пользователей за 2023 год.
 * Цель: оценка метрик по когортам пользователей (на основе месяца первой покупки) 
 * для отслеживания сезонности, изменения среднего чека, уровня удовлетворенности 
 * сервисом и продолжительности жизни клиента (lifetime).
 */

SELECT
    DATE_TRUNC('month', first_order_ts) AS first_order_month,
    COUNT(user_id) AS total_users,
    SUM(total_orders) AS total_orders,
    (SUM(total_order_costs) * 1.0 / SUM(total_orders))::numeric(7,2) AS avg_order_cost,
    ROUND(AVG(avg_order_rating), 1) AS avg_rating,
    ROUND(AVG(used_money_transfer), 2) AS used_money_transfer_ratio,
    AVG(lifetime) AS avg_lifetime
FROM ds_ecom.product_user_features
WHERE EXTRACT(YEAR FROM first_order_ts) = 2023
GROUP BY first_order_month
ORDER BY first_order_month;



/*
 * ВЫВОДЫ ПО АКТИВНОСТИ (2023 ГОД):
 * За 2023 год наблюдается устойчивый рост базы пользователей и общего объема заказов. Средняя стоимость заказа и рейтинг
 * остаются на высоком уровне на протяжении всего года, что говорит о хорошем качестве сервиса и удовлетворенности клиентов. 
 * Доля пользователей, использующих способ оплаты 'Денежный перевод', стабильно около 20%, демонстрируя постоянный интерес к данной услуге.
 * В конце года отмечается небольшое снижение активности, типичное для сезонных колебаний. В декабре наблюдается снижение количества новых 
 * пользователей и заказов по сравнению с ноябрём, а также сокращение среднего времени активности пользователей, что может быть
 * связано с праздничным сезоном, завершением финансового года или подготовкой к новому бизнес-циклу. В целом, бизнес демонстрирует положительную динамику
 * и высокий уровень клиентской лояльности.
 */





