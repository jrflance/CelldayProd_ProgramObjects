--liquibase formatted sql
--changeset MoeDaaboul:795f1910 stripComments:false runOnChange:true splitStatements:false
/*=============================================
            :
     Author : Melissa Rios
            :
    Created : 2020-08-06
            :
Description : Generates Summary Data for Post-paid invoices based on invoice number input
            :
MR20200902  : Updated the naming of "Activation Spiff" to "Instant Postpaid Spiff"
MR20200908  : Updated the naming of "Instant Postpaid Spiff" to "Postpaid Instant Spiff"
MR20211105  : Added a separate insert into #Credits and #Debits to handle Multi Forms of Payment order types.
MR20211202  : Exluded "Account Balance" Product ID and order type ID 80
MR20220121  : Per Chris' request, remove Postpaid Refund Multi Forms Of Payment and the Postpaid Multi Forms of Payment
			: And changed the order type naming to match prepaid statment changes
SK20240223	: Added Activation Fee items
=============================================*/

ALTER PROCEDURE [OrderManagment].[P_GetPostPaidInvoiceSummary]
    (@InvoiceNum VARCHAR(20))
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    --DECLARE @InvoiceNum VARCHAR(20) = '163330732'

    IF OBJECT_ID('tempdb..#Credits') IS NOT NULL
        BEGIN
            DROP TABLE #Credits;
        END;

    SELECT
        NULL AS Debit,
        CASE
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 4
                THEN
                    'Postpaid Instant Spiff'
            WHEN
                n.OrderType_ID IN (77)
                AND d.Product_ID IN (15693)
                THEN  --Purchase Credit Card products on prod
                    'Payment'						--MR20220121
            WHEN
                n.OrderType_ID IN (78)
                AND d.Product_ID IN (15693)
                THEN  --Purchase Credit Card products on prod
                    'Refund'						--MR20220121
            ELSE
                REPLACE(oti.OrderType_Desc, 'Postpaid', '') --MR20220121
        END AS [Order Type],
        SUM(d.Price) - SUM(d.DiscAmount) + SUM(ISNULL(d.Fee, 0)) AS Credit
    INTO #Credits
    FROM dbo.Order_No AS n
    JOIN dbo.Orders AS d
        ON
            n.Order_No = d.Order_No
            AND d.Price <= 0.00
    JOIN dbo.Products AS p
        ON p.Product_ID = d.Product_ID
    JOIN dbo.OrderType_ID AS oti
        ON oti.OrderType_ID = n.OrderType_ID
    WHERE
        n.Status = @InvoiceNum
        AND n.Filled = 1
        AND n.Void = 0
        AND n.Process = 1
        AND d.Product_ID NOT IN (15692)				--MR20211202 Account Balance Prod
        --MR20211105 "Postpaid Refund Multi Forms Of Payment" will be listed under Debits And excluding "Postpaid Credit Card Multi Forms Of Payment"
        AND n.OrderType_ID NOT IN (78, 80)
    GROUP BY
        CASE
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 4
                THEN
                    'Postpaid Instant Spiff'
            WHEN
                n.OrderType_ID IN (77)
                AND d.Product_ID IN (15693)
                THEN --Purchase Credit Card products on prod
                    'Payment' --MR20220121
            WHEN
                n.OrderType_ID IN (78)
                AND d.Product_ID IN (15693)
                THEN --Purchase Credit Card products on prod
                    'Refund'  --MR20220121
            ELSE
                REPLACE(oti.OrderType_Desc, 'Postpaid', '') --MR20220121
        END



    ----------------begin debits--------------------

    IF OBJECT_ID('tempdb..#Debits') IS NOT NULL
        BEGIN
            DROP TABLE #Debits;
        END;

    SELECT
        NULL AS CREDIT,
        CASE
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 4
                THEN
                    'Postpaid Instant Spiff'
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 17
                THEN -- Activation Fees
                    'Activation Fees' --SK20240223
            WHEN
                n.OrderType_ID IN (77)
                AND d.Product_ID IN (15693)
                THEN  --Purchase Credit Card products on prod
                    'Payment'						--MR20220121
            WHEN
                n.OrderType_ID IN (78)
                AND d.Product_ID IN (15693)
                THEN  --Purchase Credit Card products on prod
                    'Refund'						--MR20220121
            ELSE
                REPLACE(oti.OrderType_Desc, 'Postpaid', '')
        END AS [Order Type],
        SUM(d.Price) - SUM(d.DiscAmount) + SUM(ISNULL(d.Fee, 0)) AS Debit
    INTO #Debits
    FROM dbo.Order_No AS n
    JOIN dbo.Orders AS d
        ON
            n.Order_No = d.Order_No
            AND d.Price >= 0.00
    JOIN dbo.Products AS p
        ON p.Product_ID = d.Product_ID
    JOIN dbo.OrderType_ID AS oti
        ON oti.OrderType_ID = n.OrderType_ID
    WHERE
        n.Status = @InvoiceNum
        AND n.Filled = 1
        AND n.Void = 0
        AND n.Process = 1
        AND d.Product_ID NOT IN (15692)				--MR20211202 Account Balance
        AND n.OrderType_ID NOT IN (77, 80)	--MR20211105 Postpaid Multi Forms Of Payment to appear as a credit
    GROUP BY
        CASE
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 4
                THEN
                    'Postpaid Instant Spiff'
            WHEN
                n.OrderType_ID = 22
                AND p.Product_Type = 17
                THEN -- Activation Fees
                    'Activation Fees' --SK20240223
            WHEN
                n.OrderType_ID IN (77)
                AND d.Product_ID IN (15693)
                THEN --Purchase Credit Card products on prod
                    'Payment' --MR20220121
            WHEN
                n.OrderType_ID IN (78)
                AND d.Product_ID IN (15693)
                THEN --Purchase Credit Card products on prod
                    'Refund'  --MR20220121
            ELSE
                REPLACE(oti.OrderType_Desc, 'Postpaid', '')
        END
    ORDER BY CASE
        WHEN
            n.OrderType_ID = 22
            AND p.Product_Type = 4
            THEN
                'Postpaid Instant Spiff'
        WHEN
            n.OrderType_ID = 22
            AND p.Product_Type = 17
            THEN -- Activation Fees
                'Activation Fees' --SK20240223
        WHEN
            n.OrderType_ID IN (77)
            AND d.Product_ID IN (15693)
            THEN --Purchase Credit Card products on prod
                'Payment' --MR20220107
        WHEN
            n.OrderType_ID IN (78)
            AND d.Product_ID IN (15693)
            THEN --Purchase Credit Card products on prod
                'Refund'  --MR20220119
        ELSE
            REPLACE(oti.OrderType_Desc, 'Postpaid', '')
    END;



    SELECT
        c.[Order Type],
        c.Credit,
        d.Debit
    FROM #Credits AS c
    LEFT JOIN #Debits AS d
        ON c.[Order Type] = d.[Order Type]
    UNION
    SELECT
        d.[Order Type],
        c.Credit,
        d.Debit
    FROM #Debits AS d
    LEFT JOIN #Credits AS c
        ON c.[Order Type] = d.[Order Type]
    ORDER BY c.[Order Type];

END;
