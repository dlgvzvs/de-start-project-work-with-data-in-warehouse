-- Переношу из первоначального файла только DML-запросы. В первый раз писал всё вместе, только чтобы не запутаться и не потеряться в скрипте.
-- Есть подозрения, что при переносе запросов я мог понаделать ошибок.

/* обновление существующих записей и добавление новых в dwh.d_craftsmans */
MERGE INTO dwh.d_craftsman d
USING (SELECT DISTINCT craftsman_name, craftsman_address, craftsman_birthday, craftsman_email FROM tmp_sources) t
ON d.craftsman_name = t.craftsman_name AND d.craftsman_email = t.craftsman_email
WHEN MATCHED THEN
  UPDATE SET craftsman_address = t.craftsman_address, 
craftsman_birthday = t.craftsman_birthday, load_dttm = current_timestamp
WHEN NOT MATCHED THEN
  INSERT (craftsman_name, craftsman_address, craftsman_birthday, craftsman_email, load_dttm)
  VALUES (t.craftsman_name, t.craftsman_address, t.craftsman_birthday, t.craftsman_email, current_timestamp);

/* обновление существующих записей и добавление новых в dwh.d_products */
MERGE INTO dwh.d_product d
USING (SELECT DISTINCT product_name, product_description, product_type, product_price from tmp_sources) t
ON d.product_name = t.product_name AND d.product_description = t.product_description AND d.product_price = t.product_price
WHEN MATCHED THEN
  UPDATE SET product_type= t.product_type, load_dttm = current_timestamp
WHEN NOT MATCHED THEN
  INSERT (product_name, product_description, product_type, product_price, load_dttm)
  VALUES (t.product_name, t.product_description, t.product_type, t.product_price, current_timestamp);

/* обновление существующих записей и добавление новых в dwh.d_customer */
MERGE INTO dwh.d_customer d
USING (SELECT DISTINCT customer_name, customer_address, customer_birthday, customer_email from tmp_sources) t
ON d.customer_name = t.customer_name AND d.customer_email = t.customer_email
WHEN MATCHED THEN
  UPDATE SET customer_address= t.customer_address, 
customer_birthday= t.customer_birthday, load_dttm = current_timestamp
WHEN NOT MATCHED THEN
  INSERT (customer_name, customer_address, customer_birthday, customer_email, load_dttm)
  VALUES (t.customer_name, t.customer_address, t.customer_birthday, t.customer_email, current_timestamp);

/* обновление существующих записей и добавление новых в dwh.f_order */
MERGE INTO dwh.f_order f
USING tmp_sources_fact t
ON f.product_id = t.product_id AND f.craftsman_id = t.craftsman_id AND f.customer_id = t.customer_id AND f.order_created_date = t.order_created_date 
WHEN MATCHED THEN
  UPDATE SET order_completion_date = t.order_completion_date, order_status = t.order_status, load_dttm = current_timestamp
WHEN NOT MATCHED THEN
  INSERT (product_id, craftsman_id, customer_id, order_created_date, order_completion_date, order_status, load_dttm)
  VALUES (t.product_id, t.craftsman_id, t.customer_id, t.order_created_date, t.order_completion_date, t.order_status, current_timestamp);

WITH
dwh_delta AS ( -- определяем, какие данные были изменены в витрине или добавлены в DWH. Формируем дельту изменений
    SELECT     
            dc.craftsman_id AS craftsman_id,
            dc.craftsman_name AS craftsman_name,
            dc.craftsman_address AS craftsman_address,
            dc.craftsman_birthday AS craftsman_birthday,
            dc.craftsman_email AS craftsman_email,
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type,
            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
            fo.order_completion_date - fo.order_created_date AS diff_order_date, 
            fo.order_status AS order_status,
            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
            crd.craftsman_id AS exist_craftsman_id,
            dc.load_dttm AS craftsman_load_dttm,
            dcs.load_dttm AS customers_load_dttm,
            dp.load_dttm AS products_load_dttm
            FROM dwh.f_order fo 
                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id 
                LEFT JOIN dwh.craftsman_report_datamart crd ON dc.craftsman_id = crd.craftsman_id
                    WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart))
),
dwh_update_delta AS ( -- делаем выборку мастеров ручной работы, по которым были изменения в DWH. По этим мастерам данные в витрине нужно будет обновить
    SELECT     
            dd.exist_craftsman_id AS craftsman_id
            FROM dwh_delta dd 
                WHERE dd.exist_craftsman_id IS NOT NULL        
),
dwh_delta_insert_result AS ( -- делаем расчёт витрины по новым данным. Этой информации по мастерам в рамках расчётного периода раньше не было, это новые данные. Их можно просто вставить (insert) в витрину без обновления
    SELECT  
            T4.craftsman_id AS craftsman_id,
            T4.craftsman_name AS craftsman_name,
            T4.craftsman_address AS craftsman_address,
            T4.craftsman_birthday AS craftsman_birthday,
            T4.craftsman_email AS craftsman_email,
            T4.craftsman_money AS craftsman_money,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.avg_age_customer AS avg_age_customer,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period 
            FROM (
                SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
                        *,
                        RANK() OVER(PARTITION BY T2.craftsman_id ORDER BY count_product DESC) AS rank_count_product 
                        FROM ( 
                            SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у мастера. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                                T1.craftsman_id AS craftsman_id,
                                T1.craftsman_name AS craftsman_name,
                                T1.craftsman_address AS craftsman_address,
                                T1.craftsman_birthday AS craftsman_birthday,
                                T1.craftsman_email AS craftsman_email,
                                SUM(T1.product_price) - (SUM(T1.product_price) * 0.1) AS craftsman_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                AVG(T1.customer_age) AS avg_age_customer,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM dwh_delta AS T1
                                    WHERE T1.exist_craftsman_id IS NULL
                                        GROUP BY T1.craftsman_id, T1.craftsman_name, T1.craftsman_address, T1.craftsman_birthday, T1.craftsman_email, T1.report_period
                            ) AS T2 
                                INNER JOIN (
                                    SELECT     -- Эта выборка поможет определить самый популярный товар у мастера ручной работы. Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. Для данных этой выборки можно применить оконную функцию, которая и покажет самую популярную категорию товаров у мастера
                                            dd.craftsman_id AS craftsman_id_for_product_type, 
                                            dd.product_type, 
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.craftsman_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T3 ON T2.craftsman_id = T3.craftsman_id_for_product_type
                ) AS T4 WHERE T4.rank_count_product = 1 ORDER BY report_period -- условие помогает оставить в выборке первую по популярности категорию товаров
),
dwh_delta_update_result AS ( -- делаем перерасчёт для существующих записей витринs, так как данные обновились за отчётные периоды. Логика похожа на insert, но нужно достать конкретные данные из DWH
    SELECT 
            T4.craftsman_id AS craftsman_id,
            T4.craftsman_name AS craftsman_name,
            T4.craftsman_address AS craftsman_address,
            T4.craftsman_birthday AS craftsman_birthday,
            T4.craftsman_email AS craftsman_email,
            T4.craftsman_money AS craftsman_money,
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.avg_age_customer AS avg_age_customer,
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery, 
            T4.count_order_done AS count_order_done, 
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period 
            FROM (
                SELECT     -- в этой выборке объединяем две внутренние выборки по расчёту столбцов витрины и применяем оконную функцию для определения самой популярной категории товаров
                        *,
                        RANK() OVER(PARTITION BY T2.craftsman_id ORDER BY count_product DESC) AS rank_count_product 
                        FROM (
                            SELECT -- в этой выборке делаем расчёт по большинству столбцов, так как все они требуют одной и той же группировки, кроме столбца с самой популярной категорией товаров у мастера. Для этого столбца сделаем отдельную выборку с другой группировкой и выполним JOIN
                                T1.craftsman_id AS craftsman_id,
                                T1.craftsman_name AS craftsman_name,
                                T1.craftsman_address AS craftsman_address,
                                T1.craftsman_birthday AS craftsman_birthday,
                                T1.craftsman_email AS craftsman_email,
                                SUM(T1.product_price) - (SUM(T1.product_price) * 0.1) AS craftsman_money,
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                AVG(T1.customer_age) AS avg_age_customer,
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created, 
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM (
                                    SELECT     -- в этой выборке достаём из DWH обновлённые или новые данные по мастерам, которые уже есть в витрине
                                            dc.craftsman_id AS craftsman_id,
                                            dc.craftsman_name AS craftsman_name,
                                            dc.craftsman_address AS craftsman_address,
                                            dc.craftsman_birthday AS craftsman_birthday,
                                            dc.craftsman_email AS craftsman_email,
                                            fo.order_id AS order_id,
                                            dp.product_id AS product_id,
                                            dp.product_price AS product_price,
                                            dp.product_type AS product_type,
                                            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
                                            fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                            fo.order_status AS order_status, 
                                            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period
                                            FROM dwh.f_order fo 
                                                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                                                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                                                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                                INNER JOIN dwh_update_delta ud ON fo.craftsman_id = ud.craftsman_id
                                ) AS T1
                                    GROUP BY T1.craftsman_id, T1.craftsman_name, T1.craftsman_address, T1.craftsman_birthday, T1.craftsman_email, T1.report_period
                            ) AS T2 
                                INNER JOIN (
                                    SELECT     -- Эта выборка поможет определить самый популярный товар у мастера. Эта выборка не делается в предыдущем запросе, так как нужна другая группировка. Для данных этой выборки можно применить оконную функцию, которая и покажет самую популярную категорию товаров у мастера
                                            dd.craftsman_id AS craftsman_id_for_product_type, 
                                            dd.product_type, 
                                            COUNT(dd.product_id) AS count_product
                                            FROM dwh_delta AS dd
                                                GROUP BY dd.craftsman_id, dd.product_type
                                                    ORDER BY count_product DESC) AS T3 ON T2.craftsman_id = T3.craftsman_id_for_product_type
                ) AS T4 WHERE T4.rank_count_product = 1 ORDER BY report_period
),
insert_delta AS ( -- выполняем insert новых расчитанных данных для витрины 
    INSERT INTO dwh.craftsman_report_datamart (
        craftsman_id,
        craftsman_name,
        craftsman_address,
        craftsman_birthday, 
        craftsman_email, 
        craftsman_money, 
        platform_money, 
        count_order, 
        avg_price_order, 
        avg_age_customer,
        median_time_order_completed,
        top_product_category, 
        count_order_created, 
        count_order_in_progress, 
        count_order_delivery, 
        count_order_done, 
        count_order_not_done, 
        report_period
    ) SELECT 
            craftsman_id,
            craftsman_name,
            craftsman_address,
            craftsman_birthday,
            craftsman_email,
            craftsman_money,
            platform_money,
            count_order,
            avg_price_order,
            avg_age_customer,
            median_time_order_completed,
            top_product_category,
            count_order_created, 
            count_order_in_progress,
            count_order_delivery, 
            count_order_done, 
            count_order_not_done,
            report_period 
            FROM dwh_delta_insert_result
),
update_delta AS ( -- выполняем обновление показателей в отчёте по уже существующим мастерам
    UPDATE dwh.craftsman_report_datamart SET
        craftsman_name = updates.craftsman_name, 
        craftsman_address = updates.craftsman_address, 
        craftsman_birthday = updates.craftsman_birthday, 
        craftsman_email = updates.craftsman_email, 
        craftsman_money = updates.craftsman_money, 
        platform_money = updates.platform_money, 
        count_order = updates.count_order, 
        avg_price_order = updates.avg_price_order, 
        avg_age_customer = updates.avg_age_customer, 
        median_time_order_completed = updates.median_time_order_completed, 
        top_product_category = updates.top_product_category, 
        count_order_created = updates.count_order_created, 
        count_order_in_progress = updates.count_order_in_progress, 
        count_order_delivery = updates.count_order_delivery, 
        count_order_done = updates.count_order_done,
        count_order_not_done = updates.count_order_not_done, 
        report_period = updates.report_period
    FROM (
        SELECT 
            craftsman_id,
            craftsman_name,
            craftsman_address,
            craftsman_birthday,
            craftsman_email,
            craftsman_money,
            platform_money,
            count_order,
            avg_price_order,
            avg_age_customer,
            median_time_order_completed,
            top_product_category,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period 
            FROM dwh_delta_update_result) AS updates
    WHERE dwh.craftsman_report_datamart.craftsman_id = updates.craftsman_id
),
insert_load_date AS ( -- делаем запись в таблицу загрузок о том, когда была совершена загрузка, чтобы в следующий раз взять данные, которые будут добавлены или изменены после этой даты
    INSERT INTO dwh.load_dates_craftsman_report_datamart (
        load_dttm
    )
    SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()), 
                    COALESCE(MAX(customers_load_dttm), NOW()), 
                    COALESCE(MAX(products_load_dttm), NOW())) 
        FROM dwh_delta
)
SELECT 'increment datamart'; -- инициализируем запрос CTE



WITH
customer_dwh_delta AS ( -- меняю мастера на клиента
    SELECT     
            dc.customer_id AS customer_id, -- меняю мастера на клиента
            dc.customer_name AS customer_name, -- меняю мастера на клиента
            dc.customer_address AS customer_address, -- меняю мастера на клиента
            dc.customer_birthday AS customer_birthday, -- меняю мастера на клиента
            dc.customer_email AS customer_email, -- меняю мастера на клиента
            fo.order_id AS order_id,
            dp.product_id AS product_id,
            dp.product_price AS product_price,
            dp.product_type AS product_type,
            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age,
            fo.order_completion_date - fo.order_created_date AS diff_order_date, 
            fo.order_status AS order_status,
            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period,
            crd.craftsman_id AS exist_craftsman_id,
            dc.load_dttm AS craftsman_load_dttm,
            dcs.load_dttm AS customers_load_dttm,
            dp.load_dttm AS products_load_dttm
            FROM dwh.f_order fo
                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id 
                LEFT JOIN dwh.craftsman_report_datamart crd ON dc.craftsman_id = crd.craftsman_id
                    WHERE (fo.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dc.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dcs.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart)) OR
                            (dp.load_dttm > (SELECT COALESCE(MAX(load_dttm),'1900-01-01') FROM dwh.load_dates_craftsman_report_datamart))
),

customer_top_craftsman AS ( -- убрал лишнее слово WITH. Признаюсь, тут запутался, поэтому и допустил ошибку.
    SELECT
        cdd.customer_id AS customer_id_for_top_craftsman_id, -- выписываю ID клиентов
        cdd.craftsman_id, -- выпиываю ID мастеров
        COUNT(cdd.order_id) AS count_orders, -- считаю количество заказов конкретного мастера для конкретного клиента
        RANK() OVER (PARTITION BY cdd.customer_id ORDER BY COUNT(cdd.order_id) DESC) AS craftsman_rank -- расписываю, сколько заказов выполнил конкретный мастер для конкретного клиента
    FROM customer_dwh_delta AS cdd
    GROUP BY cdd.customer_id, cdd.craftsman_id -- группирую по парам "мастер-клиент"
),
customer_top_craftsman_filtered AS ( -- тут отбираю клиентов и мастеров с рейтингом 1
    SELECT
        customer_id_for_top_craftsman_id AS customer_id,
        craftsman_id AS top_craftsman_id
    FROM customer_top_craftsman
    WHERE craftsman_rank = 1
),
customer_update_delta AS ( -- меняю мастера на клиента
    SELECT     
            cdd.exist_customer_id AS customer_id -- меняю мастера на клиента
            FROM customer_dwh_delta cdd -- теперь ссылаюсь на новую дельту
                WHERE cdd.exist_customer_id IS NOT NULL -- меняю мастера на клиента     
),
customer_delta_insert_result AS ( -- меняю мастера на клиента
    SELECT  
            T4.customer_id AS customer_id, -- меняю мастера на клиента
            T4.customer_name AS customer_name, -- меняю мастера на клиента
            T4.customer_address AS customer_address, -- меняю мастера на клиента
            T4.customer_birthday AS customer_birthday, -- меняю мастера на клиента
            T4.customer_email AS customer_email, -- меняю мастера на клиента
            T4.total_spent AS total_spent, -- меняю доходы мастера на затраты клиента
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.customer_age AS customer_age, -- исправляю возраст клиента
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery,
            T4.count_order_done AS count_order_done,
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period,
            T5.top_craftsman_id AS top_craftsman_id -- добавляю ссылку на топ-мастера
            FROM ( -- начало Т4 (это для меня, чтобы я не потерялся, плохо ориентируюсь в большом скрипте)
                SELECT
                        *,
                        RANK() OVER(PARTITION BY T2.customer_id ORDER BY count_product DESC) AS rank_count_product -- меняю мастера на клиента
                        FROM ( -- начало Т2
                            SELECT
                                T1.customer_id AS customer_id, -- меняю мастера на клиента
                                T1.customer_name AS customer_name, -- меняю мастера на клиента
                                T1.customer_address AS customer_address, -- меняю мастера на клиента
                                T1.customer_birthday AS customer_birthday, -- меняю мастера на клиента
                                T1.customer_email AS customer_email, -- меняю мастера на клиента
                                SUM(T1.product_price) AS total_spent, -- меняю доходы мастера на затраты клиента
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                T1.customer_age AS customer_age, -- исправляю возраст клиента
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created,
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM customer_dwh_delta AS T1 -- теперь ссылаюсь на новую дельту
                                    WHERE T1.exist_customer_id IS NULL
                                        GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period
                            ) AS T2
                                INNER JOIN ( -- начало Т3
                                    SELECT
                                            cdd.customer_id AS customer_id_for_product_type, -- меняю мастера на клиента
                                            cdd.product_type, -- теперь ссылаюсь на новую дельту
                                            COUNT(cdd.product_id) AS count_product -- теперь ссылаюсь на новую дельту
                                            FROM customer_dwh_delta AS cdd -- вот она
                                                GROUP BY cdd.customer_id, cdd.product_type -- теперь ссылаюсь на новую дельту
                                                    ORDER BY count_product DESC) AS T3 ON T2.customer_id = T3.customer_id_for_product_type -- меняю мастера на клиента
                                                    INNER JOIN customer_top_craftsman_filtered AS T5 ON T2.customer_id = T5.customer_id -- 
                ) AS T4 WHERE T4.rank_count_product = 1 ORDER BY report_period
),
customer_delta_update_result AS ( -- меняю мастера на клиента
    SELECT 
            T4.customer_id AS customer_id, -- меняю мастера на клиента
            T4.customer_name AS customer_name, -- меняю мастера на клиента
            T4.customer_address AS customer_address, -- меняю мастера на клиента
            T4.customer_birthday AS customer_birthday, -- меняю мастера на клиента
            T4.customer_email AS customer_email, -- меняю мастера на клиента
            T4.total_spent AS total_spent, -- меняю доходы мастера на затраты клиента
            T4.platform_money AS platform_money,
            T4.count_order AS count_order,
            T4.avg_price_order AS avg_price_order,
            T4.customer_age AS customer_age, -- исправляю возраст клиента
            T4.product_type AS top_product_category,
            T4.median_time_order_completed AS median_time_order_completed,
            T4.count_order_created AS count_order_created,
            T4.count_order_in_progress AS count_order_in_progress,
            T4.count_order_delivery AS count_order_delivery, 
            T4.count_order_done AS count_order_done, 
            T4.count_order_not_done AS count_order_not_done,
            T4.report_period AS report_period 
            FROM ( -- начало Т4
                SELECT
                        *,
                        RANK() OVER(PARTITION BY T2.customer_id ORDER BY count_product DESC) AS rank_count_product -- меняю мастера на клиента
                        FROM ( -- начало Т2
                            SELECT
                                T1.customer_id AS customer_id, -- меняю мастера на клиента
                                T1.customer_name AS customer_name, -- меняю мастера на клиента
                                T1.customer_address AS customer_address, -- меняю мастера на клиента
                                T1.customer_birthday AS customer_birthday, -- меняю мастера на клиента
                                T1.customer_email AS customer_email, -- меняю мастера на клиента
                                SUM(T1.product_price) AS total_spent, -- меняю доходы мастера на затраты клиента
                                SUM(T1.product_price) * 0.1 AS platform_money,
                                COUNT(order_id) AS count_order,
                                AVG(T1.product_price) AS avg_price_order,
                                T1.customer_age AS customer_age, -- исправляю возраст клиента
                                PERCENTILE_CONT(0.5) WITHIN GROUP(ORDER BY diff_order_date) AS median_time_order_completed,
                                SUM(CASE WHEN T1.order_status = 'created' THEN 1 ELSE 0 END) AS count_order_created, 
                                SUM(CASE WHEN T1.order_status = 'in progress' THEN 1 ELSE 0 END) AS count_order_in_progress, 
                                SUM(CASE WHEN T1.order_status = 'delivery' THEN 1 ELSE 0 END) AS count_order_delivery, 
                                SUM(CASE WHEN T1.order_status = 'done' THEN 1 ELSE 0 END) AS count_order_done, 
                                SUM(CASE WHEN T1.order_status != 'done' THEN 1 ELSE 0 END) AS count_order_not_done,
                                T1.report_period AS report_period
                                FROM ( -- начало Т1
                                    SELECT
                                            dc.customer_id AS customer_id, -- меняю мастера на клиента
                                            dc.customer_name AS customer_name, -- меняю мастера на клиента
                                            dc.customer_address AS customer_address, -- меняю мастера на клиента
                                            dc.customer_birthday AS customer_birthday, -- меняю мастера на клиента
                                            dc.customer_email AS customer_email, -- меняю мастера на клиента
                                            fo.order_id AS order_id,
                                            dp.product_id AS product_id,
                                            dp.product_price AS product_price,
                                            dp.product_type AS product_type,
                                            DATE_PART('year', AGE(dcs.customer_birthday)) AS customer_age, -- пока не понимаю, так и оставить?
                                            fo.order_completion_date - fo.order_created_date AS diff_order_date,
                                            fo.order_status AS order_status, 
                                            TO_CHAR(fo.order_created_date, 'yyyy-mm') AS report_period
                                            FROM dwh.f_order fo 
                                                INNER JOIN dwh.d_craftsman dc ON fo.craftsman_id = dc.craftsman_id 
                                                INNER JOIN dwh.d_customer dcs ON fo.customer_id = dcs.customer_id 
                                                INNER JOIN dwh.d_product dp ON fo.product_id = dp.product_id
                                                INNER JOIN dwh_update_delta ud ON fo.craftsman_id = ud.craftsman_id
                                ) AS T1
                                    GROUP BY T1.customer_id, T1.customer_name, T1.customer_address, T1.customer_birthday, T1.customer_email, T1.report_period -- меняю мастера на клиента
                            ) AS T2 
                                INNER JOIN ( -- начало Т3
                                    SELECT
                                            cdd.customer_id AS customer_id_for_product_type, -- меняю мастера на клиента
                                            cdd.product_type, -- теперь ссылаюсь на новую дельту
                                            COUNT(cdd.product_id) AS count_product -- теперь ссылаюсь на новую дельту
                                            FROM customer_dwh_delta AS cdd -- вот она
                                                GROUP BY cdd.customer_id, cdd.product_type -- теперь ссылаюсь на новую дельту
                                                    ORDER BY count_product DESC) AS T3 ON T2.customer_id = T3.customer_id_for_product_type -- меняю мастера на клиента
                ) AS T4 WHERE T4.rank_count_product = 1 ORDER BY report_period -- тут тоже под вопросом, пока решил оставить как было
),
customer_insert_delta AS ( -- меняю мастера на клиента
    INSERT INTO dwh.customer_report_datamart ( -- меняю мастера на клиента
        customer_id, -- меняю мастера на клиента
        customer_name, -- меняю мастера на клиента
        customer_address, -- меняю мастера на клиента
        customer_birthday,  -- меняю мастера на клиента
        customer_email,  -- меняю мастера на клиента
        total_spent, -- меняю доходы мастера на затраты клиента
        platform_money, 
        count_order, 
        avg_price_order, 
        customer_age, --  исправляю возраст клиента
        median_time_order_completed,
        top_product_category, 
        count_order_created, 
        count_order_in_progress, 
        count_order_delivery, 
        count_order_done, 
        count_order_not_done, 
        report_period
    ) SELECT 
            customer_id, -- тут всё как выше - меняю мастера на клиента
            customer_name, -- меняю мастера на клиента
            customer_address, -- меняю мастера на клиента
            customer_birthday, -- меняю мастера на клиента
            customer_email, -- меняю мастера на клиента
            total_spent, -- меняю доходы мастера на затраты клиента
            platform_money,
            count_order,
            avg_price_order,
            customer_age, --  исправляю возраст клиента
            median_time_order_completed,
            top_product_category,
            count_order_created, 
            count_order_in_progress,
            count_order_delivery, 
            count_order_done, 
            count_order_not_done,
            report_period 
            FROM customer_delta_insert_result -- теперь ссылаюсь на новую дельту
),
customer_update_delta AS ( -- меняю мастера на клиента
    UPDATE dwh.customer_report_datamart SET -- обновляю новую витрину
        customer_name = updates.customer_name, -- меняю мастера на клиента
        customer_address = updates.customer_address, -- меняю мастера на клиента 
        customer_birthday = updates.customer_birthday, -- меняю мастера на клиента
        customer_email = updates.customer_email, -- меняю мастера на клиента
        total_spent = updates.total_spent, -- меняю доходы мастера на затраты клиента
        platform_money = updates.platform_money, -- тут пока не уверен, пока оставлю как было
        count_order = updates.count_order, 
        avg_price_order = updates.avg_price_order, 
        customer_age = updates.customer_age, --  исправляю возраст клиента
        median_time_order_completed = updates.median_time_order_completed, 
        top_product_category = updates.top_product_category, 
        count_order_created = updates.count_order_created, 
        count_order_in_progress = updates.count_order_in_progress, 
        count_order_delivery = updates.count_order_delivery, 
        count_order_done = updates.count_order_done,
        count_order_not_done = updates.count_order_not_done, 
        report_period = updates.report_period
    FROM (
        SELECT 
            customer_id, -- всё аналогично
            customer_name,
            customer_address,
            customer_birthday,
            customer_email,
            total_spent,
            platform_money,
            count_order,
            avg_price_order,
            customer_age,
            median_time_order_completed,
            top_product_category,
            count_order_created,
            count_order_in_progress,
            count_order_delivery,
            count_order_done,
            count_order_not_done,
            report_period 
            FROM customer_delta_update_result) AS updates -- теперь ссылаюсь на новую дельту
    WHERE dwh.customer_report_datamart.customer_id = updates.customer_id -- меняю мастера на клиента
),
insert_load_date AS (
    INSERT INTO dwh.load_dates_customer_report_datamart ( -- меняю мастера на клиента, а далее без изменений (пока)
        load_dttm
    )
    SELECT GREATEST(COALESCE(MAX(craftsman_load_dttm), NOW()), 
                    COALESCE(MAX(customers_load_dttm), NOW()), 
                    COALESCE(MAX(products_load_dttm), NOW())) 
        FROM customer_dwh_delta cdd
)
SELECT 'increment datamart';
