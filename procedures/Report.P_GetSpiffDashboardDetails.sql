--liquibase formatted sql
--changeset saialladi:795f1910576 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             :
--      Author : Jacob Lowe
--             :
--     Created : 2019-06-14
--             :
--  JL20190807 : Wrap price in isnull
--  MR20200623 : Added Verizon.tblCarrierCommissionProductMapping and IFF statement to the retro spiff section
--  BS20230315 : Added Sim Number to results
--  BS20230327 : Added key value search functionality, currently supporting IMEI search
--  SK20230330 : Added Search filter for SIM/ICCID type
--  BS20230414 : Added support to return all carriers and carrier name
--  ZS20240625 : added no commision reason from dealer commission details to instant and retro spiff
-- =============================================
ALTER PROCEDURE [Report].[P_GetSpiffDashboardDetails]
    (
        @Account_ID INT,
        @Carrier_ID INT = NULL,
        @StartDate DATETIME,
        @EndDate DATETIME,
        @SearchValues INCENTIVEDASHBOARDSEARCH READONLY
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET FMTONLY OFF;

    IF OBJECT_ID('tempdb..#CleanSearchValues') IS NOT NULL
        BEGIN
            DROP TABLE #CleanSearchValues;
        END;

    SELECT sv.[Key], sv.[Value]
    INTO #CleanSearchValues
    FROM @SearchValues AS sv
    WHERE ISNULL(sv.[Value], '') != ''

    DECLARE @IMEISearchKey VARCHAR(100) = 'IMEI'

    DECLARE
        @Products TABLE
        (
            ProductID INT,
            PaymentType VARCHAR(MAX)
        );
    INSERT INTO @Products
    (
        ProductID,
        PaymentType
    )
    SELECT DISTINCT
        ProductID,
        CASE BPProcessTypeID AS BPProcessTypeID
            WHEN 1
                THEN
                    'SecondMonth'
            WHEN 2
                THEN
                    'ThirdMonth'
            WHEN 6
                THEN
                    'SecondMonth'
            WHEN 7
                THEN
                    'ThirdMonth'
            WHEN 8
                THEN
                    'Promo'
            WHEN 9
                THEN
                    'Promo'
            WHEN 12
                THEN
                    'Promo'
            WHEN 13
                THEN
                    'Promo'
            ELSE
                'Unknown'
        END
    FROM Billing.tblBPProductMapping
    WHERE BPProcessTypeID IN (1, 2, 6, 7, 8, 9, 12, 13)
    UNION
    SELECT DISTINCT
        Product_id,
        CASE CommissionType AS CommissionType
            WHEN 'ACTIVATION SPIFF ADJUSTMENT'
                THEN
                    'FirstMonth'
            WHEN 'MONTH 2 PORT IN SPIFF'
                THEN
                    'PortSecondMonth'
            WHEN 'MONTH 2 SPIFF'
                THEN
                    'SecondMonth'
            WHEN 'MONTH 3 PORT IN SPIFF'
                THEN
                    'PortThirdMonth'
            WHEN 'MONTH 3 SPIFF'
                THEN
                    'ThirdMonth'
            WHEN 'PORT IN SPIFF'
                THEN
                    'PortFirstMonth'
            ELSE
                'Promo'
        END
    FROM Tracfone.tblCarrierCommissionProductMapping
    UNION
    SELECT DISTINCT
        Product_id,
        CASE CommissionType AS CommissionType
            WHEN 'MONTH 2 SPIFF'
                THEN
                    'SecondMonth'
            WHEN 'MONTH 3 SPIFF'
                THEN
                    'ThirdMonth'
            ELSE
                'Promo'
        END
    FROM Verizon.tblCarrierCommissionProductMapping
    IF OBJECT_ID('tempdb..#OrderNo') IS NOT NULL
        BEGIN
            DROP TABLE #OrderNo;
        END;
    SELECT
        n.Order_No,
        n.DateOrdered,
        o.Name,
        pcm.CarrierId,
        c.Carrier_Name AS CarrierName,
        n.Status,
        n.DateDue,
        oia.AddonsValue AS [IMEI]
        , oia2.AddonsValue AS [Sim]
        , o.Dropship_Note AS [Tier]
        , ISNULL(lu.UserName, u.UserName) AS [UserName]
    INTO #OrderNo
    FROM dbo.Order_No AS n
    JOIN dbo.Users AS u
        ON u.User_ID = n.User_ID
    LEFT JOIN Account.tblAccountUserLink AS aul
        ON aul.LinkedUserID = n.User_ID
    LEFT JOIN dbo.Users AS lu
        ON aul.UserID = lu.User_ID
    JOIN dbo.Orders AS o
        ON
            o.Order_No = n.Order_No
            AND o.ParentItemID = 0
    JOIN Products.tblProductCarrierMapping AS pcm
        ON
            o.Product_ID = pcm.ProductId
            AND pcm.CarrierId = ISNULL(@Carrier_ID, pcm.CarrierId)
    JOIN dbo.Carrier_ID AS c ON c.ID = pcm.CarrierId
    LEFT JOIN dbo.tblOrderItemAddons AS oia
        ON
            oia.OrderID = o.ID
            AND oia.AddonsID IN (SELECT f.AddonID FROM dbo.tblAddonFamily AS f WHERE f.AddonTypeName IN ('DeviceType', 'DeviceBYOPType'))
    LEFT JOIN dbo.tblOrderItemAddons AS oia2
        ON
            oia2.OrderID = o.ID
            AND oia2.AddonsID IN (SELECT f.AddonID FROM dbo.tblAddonFamily AS f WHERE f.AddonTypeName IN ('SimType', 'SimBYOPType'))
    WHERE
        n.Account_ID = @Account_ID
        AND n.DateOrdered
        BETWEEN @StartDate AND @EndDate
        AND n.OrderType_ID IN (22, 23)
        AND n.Filled = 1
        AND n.Void = 0
        AND
        (
            NOT EXISTS (SELECT 1 FROM #CleanSearchValues AS csv WHERE csv.[Key] = @IMEISearchKey)
            OR
            EXISTS (
                SELECT 1
                FROM #CleanSearchValues AS csv
                WHERE
                    csv.[Key] = @IMEISearchKey
                    AND csv.[Value] = oia.AddonsValue
            )
            OR
            EXISTS (
                SELECT 1
                FROM #CleanSearchValues AS csv
                WHERE
                    csv.[Key] = @IMEISearchKey
                    AND csv.[Value] = oia2.AddonsValue
            )
        )

    IF OBJECT_ID('tempdb..#DeviceSKUs') IS NOT NULL
        BEGIN
            DROP TABLE #DeviceSKUs;
        END;

    SELECT DISTINCT n.IMEI, p.[Name] AS SKU
    INTO #DeviceSKUs
    FROM #OrderNo AS n
    JOIN dbo.Phone_Active_Kit AS pak ON pak.Sim_ID = n.IMEI
    JOIN dbo.Products AS p ON p.Product_ID = pak.Product_ID

    IF OBJECT_ID('tempdb..#Auth') IS NOT NULL
        BEGIN
            DROP TABLE #Auth;
        END;
    SELECT
        n2.Order_No,
        n2.Filled,
        n2.Void,
        n2.Status,
        n2.DateDue,
        n2.OrderType_ID,
        n2.AuthNumber,
        n2.DateOrdered
    INTO #Auth
    FROM dbo.Order_No AS n2
    JOIN #OrderNo AS t
        ON
            n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
            AND n2.DateOrdered > t.DateOrdered
    WHERE n2.OrderType_ID IN (45, 46, 59, 60, 30, 34, 31, 32) AND n2.Account_ID = @Account_ID
    --Instant
    SELECT
        t.Order_No AS [ActivationOrderNumber],
        t.Order_No AS [OrderNumber],
        ISNULL(o.Price, 0) AS [Amt],
        'Spiff' AS [Type],
        'FirstMonth' AS [SubType],
        'Approved' AS [Status],
        t.DateOrdered AS [Date_Ordered],
        t.UserName AS [User],
        t.Name AS [ActivationProductName],
        t.CarrierName,
        CAST(ISNULL(t.Status, '') AS INT) AS [InvoiceOrderNumber],
        ISNULL(t.DateDue, '1900-01-01') AS [Invoice_Date],
        de.NON_COMMISSIONED_REASON AS [Ineligible_Reason],
        ds.SKU AS [SKU],
        t.IMEI AS [Device],
        t.Sim,
        '' AS [Ban],
        '' AS [Min],
        t.Tier
    FROM #OrderNo AS t
    JOIN dbo.Orders AS o
        ON
            o.Order_No = t.Order_No
            AND o.ParentItemID <> 0
    JOIN dbo.Products ON Products.Product_ID = o.Product_ID AND Products.Product_Type = 4
    LEFT JOIN #DeviceSKUs AS ds ON ds.IMEI = t.IMEI
    LEFT JOIN dbo.tblOrderItemAddons AS oia ON oia.OrderID = o.ID AND oia.AddonsID = 196
    LEFT JOIN Tracfone.tblDealerCommissionDetail AS de ON de.RTR_TXN_REFERENCE1 = oia.AddonsValue
    WHERE o.Price <> 0
    UNION ALL
    --Retro
    SELECT
        t.Order_No AS [ActivationOrderNumber],
        n2.Order_No AS [OrderNumber],
        ISNULL(o.Price, 0) AS [Amt],
        'Spiff' AS [Type],
        IIF(t.CarrierId = 7, ISNULL(p.PaymentType, 'FirstMonth'), 'FirstMonth') AS [SubType],
        CASE
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Approved'
            WHEN
                n2.Filled = 0
                AND n2.Void = 0
                THEN
                    'Pending'
            WHEN
                n2.Filled = 0
                AND n2.Void = 1
                THEN
                    'Denied'
            ELSE
                'Unknown'
        END AS [Status],
        t.DateOrdered AS [Date_Ordered],
        t.UserName AS [User],
        t.Name AS [ActivationProductName],
        t.CarrierName,
        CAST(ISNULL(n2.Status, '') AS INT) AS [InvoiceOrderNumber],
        CASE
            WHEN n2.Filled = 1
                THEN
                    ISNULL(n2.DateDue, '1900-01-01')
            ELSE
                '1900-01-01'
        END AS [Invoice_Date],
        de.NON_COMMISSIONED_REASON AS [Ineligible_Reason],
        ds.SKU AS [SKU],
        t.IMEI AS [Device],
        t.Sim,
        '' AS [Ban],
        '' AS [Min],
        t.Tier
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON
            n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
            AND n2.DateOrdered > t.DateOrdered
    JOIN dbo.Orders AS o
        ON o.Order_No = n2.Order_No
    LEFT JOIN #DeviceSKUs AS ds ON ds.IMEI = t.IMEI
    LEFT JOIN @Products AS p
        ON o.Product_ID = p.ProductID
    LEFT JOIN dbo.tblOrderItemAddons AS oia ON oia.OrderID = o.ID AND oia.AddonsID = 196
    LEFT JOIN Tracfone.tblDealerCommissionDetail AS de ON de.RTR_TXN_REFERENCE1 = oia.AddonsValue
    WHERE n2.OrderType_ID IN (45, 46)
    UNION ALL
    --Promo and Reverse VZW
    SELECT
        t.Order_No AS [ActivationOrderNumber],
        n2.Order_No AS [OrderNumber],
        ISNULL(o.Price, 0) AS [Amt],
        CASE
            WHEN o.Dropship_Qty = 25
                THEN
                    'ChargBack'
            ELSE
                'Rebate'
        END AS [Type],
        'FirstMonth' AS [SubType],
        CASE
            WHEN o.Dropship_Qty = 25
                THEN
                    'ChargeBack'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Approved'
            WHEN
                n2.Filled = 0
                AND n2.Void = 0
                THEN
                    'Pending'
            ELSE
                'Unknown'
        END AS [Status],
        t.DateOrdered AS [Date_Ordered],
        t.UserName AS [User],
        t.Name AS [ActivationProductName],
        t.CarrierName,
        CAST(ISNULL(n2.Status, '') AS INT) AS [InvoiceOrderNumber],
        CASE
            WHEN n2.Filled = 1
                THEN
                    ISNULL(n2.DateDue, '1900-01-01')
            ELSE
                '1900-01-01'
        END AS [Invoice_Date],
        CASE
            WHEN o.Dropship_Qty = 25
                THEN
                    'Device Not Eligible for Spiff'
            ELSE
                ''
        END AS [Ineligible_Reason],
        ds.SKU AS [SKU],
        t.IMEI AS [Device],
        t.Sim,
        '' AS [Ban],
        '' AS [Min],
        t.Tier
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON
            n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
            AND n2.DateOrdered > t.DateOrdered
    JOIN dbo.Orders AS o
        ON o.Order_No = n2.Order_No
    LEFT JOIN #DeviceSKUs AS ds ON ds.IMEI = t.IMEI
    WHERE n2.OrderType_ID IN (59, 60) --Promo

    UNION ALL
    --additionalMonth
    SELECT
        t.Order_No AS [ActivationOrderNumber],
        n2.Order_No AS [OrderNumber],
        ISNULL(o.Price, 0) AS [Amt],
        CASE
            WHEN n2.OrderType_ID IN (30, 34) THEN 'Spiff'
            WHEN n2.OrderType_ID IN (59, 60) THEN 'Rebate'
            ELSE 'N/A'
        END AS [Type],
        p.PaymentType AS [SubType],
        CASE
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Approved'
            WHEN
                n2.Filled = 0
                AND n2.Void = 0
                THEN
                    'Pending'
            WHEN
                n2.Filled = 0
                AND n2.Void = 1
                THEN
                    'Denied'
            ELSE
                'Unknown'
        END AS [Status],
        t.DateOrdered AS [Date_Ordered],
        t.UserName AS [User],
        t.Name AS [ActivationProductName],
        t.CarrierName,
        CAST(ISNULL(n2.Status, '') AS INT) AS [InvoiceOrderNumber],
        CASE
            WHEN n2.Filled = 1
                THEN
                    ISNULL(n2.DateDue, '1900-01-01')
            ELSE
                '1900-01-01'
        END AS [Invoice_Date],
        '' AS [Ineligible_Reason],
        ds.SKU AS [SKU],
        t.IMEI AS [Device],
        t.Sim,
        '' AS [Ban],
        '' AS [Min],
        t.Tier
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON
            n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
            AND n2.DateOrdered > t.DateOrdered
    JOIN dbo.Orders AS o
        ON o.Order_No = n2.Order_No
    JOIN @Products AS p
        ON o.Product_ID = p.ProductID
    LEFT JOIN #DeviceSKUs AS ds ON ds.IMEI = t.IMEI
    WHERE n2.OrderType_ID IN (30, 34) --Additional
    UNION ALL
    --Chargeback
    SELECT
        t.Order_No AS [ActivationOrderNumber],
        n2.Order_No AS [OrderNumber],
        ISNULL(o.Price, 0) AS [Amt],
        'ChargeBack' AS [Type],
        '' AS [SubType],
        'ChargeBack' AS [Status],
        t.DateOrdered AS [Date_Ordered],
        t.UserName AS [User],
        t.Name AS [ActivationProductName],
        t.CarrierName,
        CAST(ISNULL(n2.Status, '') AS INT) AS [InvoiceOrderNumber],
        CASE
            WHEN n2.Filled = 1
                THEN
                    ISNULL(n2.DateDue, '1900-01-01')
            ELSE
                '1900-01-01'
        END AS [Invoice_Date],
        '' AS [Ineligible_Reason],
        ds.SKU AS [SKU],
        t.IMEI AS [Device],
        t.Sim,
        '' AS [Ban],
        '' AS [Min],
        t.Tier
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON
            n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
            AND n2.DateOrdered > t.DateOrdered
    JOIN dbo.Orders AS o
        ON o.Order_No = n2.Order_No
    LEFT JOIN #DeviceSKUs AS ds ON ds.IMEI = t.IMEI
    WHERE
        n2.OrderType_ID IN (31, 21)
        AND n2.Void = 0 AND n2.Filled = 1
    --ChargeBacks
    UNION ALL
    -- Activation Fee
    SELECT
        t.Order_No AS [ActivationOrderNumber],
        t.Order_No AS [OrderNumber],
        ISNULL(o.Price, 0) - ISNULL(o.DiscAmount, 0) AS [Amt],
        'Fees' AS [Type],
        '' AS [SubType],
        'Approved' AS [Status],
        t.DateOrdered AS [Date_Ordered],
        t.UserName AS [User],
        t.Name AS [ActivationProductName],
        t.CarrierName,
        CAST(ISNULL(t.Status, '') AS INT) AS [InvoiceOrderNumber],
        ISNULL(t.DateDue, '1900-01-01') AS [Invoice_Date],
        '' AS [Ineligible_Reason],
        ds.SKU AS [SKU],
        t.IMEI AS [Device],
        t.Sim,
        '' AS [Ban],
        '' AS [Min],
        t.Tier
    FROM #OrderNo AS t
    JOIN dbo.Orders AS o
        ON
            o.Order_No = t.Order_No
            AND o.ParentItemID <> 0
    JOIN dbo.Products ON Products.Product_ID = o.Product_ID AND Products.Product_Type = 17
    LEFT JOIN #DeviceSKUs AS ds ON ds.IMEI = t.IMEI
    WHERE o.Price <> 0
    ORDER BY t.Order_No;
END;
