--liquibase formatted sql
--changeset MoeDaaboul:795f1910 stripComments:false runOnChange:true splitStatements:false
/*****************************************************************************************************
 Author  : Jacob Lowe
 Created  : 2019-06-14

 History Log :
  2019-08-20 - Jacob Lowe
   Split #AuthProcessedV1
  2020-02-26 - Morgan Kemp
   Altered flower bock to show history in a more optimized manner
   Modified Chargeback/Rebate block to allow rebated to pass through logic as expected
    This in support of story TAC20-384; addition inline comments can be found below
  2023-03-27 - Brandon Stahl
   Added key value search functionality, currently supporting IMEI search
  2023-03-30 - Sai Krishna
  Added Search filter for SIM/ICCID type
  2024-02-20- Sai Krishna
  Added condition for parentitemid and spiff orders to look for spiff producttype
*****************************************************************************************************/
ALTER PROCEDURE [Report].[P_GetSpiffDashboardHeader]
    (
        @Account_ID INT,
        @StartDate DATETIME,
        @EndDate DATETIME,
        @SearchValues INCENTIVEDASHBOARDSEARCH READONLY
    )
AS
BEGIN
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
    SET FMTONLY OFF;

    DECLARE
        @IMEISearchKey VARCHAR(100) = 'IMEI'

    IF OBJECT_ID('tempdb..#CleanSearchValues') IS NOT NULL
        BEGIN
            DROP TABLE #CleanSearchValues;
        END;

    SELECT sv.[Key], sv.[Value]
    INTO #CleanSearchValues
    FROM @SearchValues AS sv
    WHERE ISNULL(sv.[Value], '') != ''


    DECLARE
        @Products TABLE
        (
            ProductID INT
        );

    INSERT INTO @Products
    (
        ProductID
    )
    SELECT DISTINCT
        ProductID
    FROM Billing.tblBPProductMapping
    WHERE BPProcessTypeID IN (1, 2, 6, 7, 8, 9, 12, 13)
    UNION
    SELECT DISTINCT
        Product_id
    FROM Tracfone.tblCarrierCommissionProductMapping;

    IF OBJECT_ID('tempdb..#OrderNo') IS NOT NULL
        BEGIN
            DROP TABLE #OrderNo;
        END;

    SELECT
        n.Order_No,
        n.DateOrdered,
        pcm.CarrierId,
        c.Carrier_Name,
        n.Void,
        n.Filled,
        n.OrderType_ID
    INTO #OrderNo
    FROM dbo.Order_No AS n
    JOIN dbo.Orders AS o
        ON
            o.Order_No = n.Order_No
            AND o.ParentItemID = 0
    JOIN Products.tblProductCarrierMapping AS pcm
        ON o.Product_ID = pcm.ProductId
    JOIN dbo.Carrier_ID AS c
        ON c.ID = pcm.CarrierId
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
                FROM dbo.tblOrderItemAddons AS oia
                JOIN
                    dbo.tblAddonFamily AS af
                    ON oia.AddonsID = af.AddonID AND af.AddonTypeName IN ('DeviceType', 'DeviceBYOPType', 'SimType', 'SimBYOPType')
                JOIN dbo.Orders AS os ON o.Order_No = os.Order_No AND oia.OrderID = o.ID
                JOIN #CleanSearchValues AS csv ON csv.[Value] = oia.AddonsValue
            )
        )


    IF OBJECT_ID('tempdb..#Auth') IS NOT NULL
        BEGIN
            DROP TABLE #Auth;
        END;
    SELECT DISTINCT
        n2.Order_No,
        n2.DateOrdered,
        n2.Void,
        n2.Filled,
        n2.OrderType_ID,
        n2.AuthNumber
    INTO #Auth
    FROM dbo.Order_No AS n2
    JOIN #OrderNo AS t
        ON
            n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
            AND n2.DateOrdered > t.DateOrdered
    WHERE
        n2.OrderType_ID IN (45, 46, 59, 60, 30, 34, 31, 32)
        AND n2.Account_ID = @Account_ID;

    DELETE FROM #Auth
    WHERE
        OrderType_ID IN (59, 60)
        AND
        (
            Void = 1
            OR Filled = 0
        );

    IF OBJECT_ID('tempdb..#AuthProcessedV1') IS NOT NULL
        BEGIN
            DROP TABLE #AuthProcessedV1;
        END;

    SELECT
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber,
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END AS [Status],
        'Spiff' AS [GroupType],
        ISNULL(SUM(ISNULL(o.Price, 0) - ISNULL(o.DiscAmount, 0) + ISNULL(o.Fee, 0)), 0) AS [Amt]
    INTO #AuthProcessedV1
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
    JOIN dbo.Orders AS o
        ON n2.Order_No = o.Order_No
    WHERE n2.OrderType_ID IN (45, 46)
    GROUP BY
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END,
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber
    UNION ALL
    SELECT
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber,
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END AS [Status],
        CASE
            WHEN
                n2.OrderType_ID IN (59, 60)
                AND ISNULL(o.Dropship_Qty, 0) = 25
                THEN
                    'ChargeBack'
            ELSE
                'Rebate'
        END AS [GroupType],
        ISNULL(SUM(ISNULL(o.Price, 0) - ISNULL(o.DiscAmount, 0) + ISNULL(o.Fee, 0)), 0) AS [Amt]
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
    JOIN dbo.Orders AS o
        ON n2.Order_No = o.Order_No
    WHERE n2.OrderType_ID IN (59, 60)
    /* Morgan Kemp - Commenting out so that GroupType Rebate can come through the logic as expected*/
    --AND ISNULL(o.Dropship_Qty, 0) = 25
    GROUP BY
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END,
        CASE
            WHEN
                n2.OrderType_ID IN (59, 60)
                AND ISNULL(o.Dropship_Qty, 0) = 25
                THEN
                    'ChargeBack'
            ELSE
                'Rebate'
        END,
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber
    UNION ALL
    SELECT
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber,
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END AS [Status],
        'ChargeBack' AS [GroupType],
        ISNULL(SUM(ISNULL(o.Price, 0) - ISNULL(o.DiscAmount, 0) + ISNULL(o.Fee, 0)), 0) AS [Amt]
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
    JOIN dbo.Orders AS o
        ON n2.Order_No = o.Order_No
    WHERE
        n2.OrderType_ID IN (31, 32)
        AND n2.Filled = 1
        AND n2.Void = 0
    GROUP BY
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END,
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber
    UNION ALL
    SELECT
        t.Order_No,
        t.DateOrdered,
        t.Order_No,
        CASE
            WHEN t.Void = 1
                THEN
                    'Void'
            WHEN
                t.Filled = 1
                AND t.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END AS [Status], 'Spiff' AS [GroupType],
        ISNULL(SUM(ISNULL(o.Price, 0) - ISNULL(o.DiscAmount, 0) + ISNULL(o.Fee, 0)), 0) AS [Amt]
    FROM #OrderNo AS t
    JOIN dbo.Orders AS o
        ON o.Order_No = t.Order_No
    JOIN dbo.Products AS p
        ON
            p.Product_ID = o.Product_ID
            AND o.ParentItemID <> 0 AND p.Product_Type = 4 -- SK20240220
    WHERE o.Price <> 0
    GROUP BY
        CASE
            WHEN t.Void = 1
                THEN
                    'Void'
            WHEN
                t.Filled = 1
                AND t.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END,
        t.Order_No,
        t.DateOrdered
    UNION ALL
    SELECT
        n2.Order_No,
        n2.DateOrdered,
        n2.AuthNumber,
        CASE
            WHEN n2.Void = 1
                THEN
                    'Void'
            WHEN
                n2.Filled = 1
                AND n2.Void = 0
                THEN
                    'Filled'
            ELSE
                'Pending'
        END AS [Status],
        'Spiff' AS [GroupType],
        ISNULL(SUM(ISNULL(o.Price, 0) - ISNULL(o.DiscAmount, 0) + ISNULL(o.Fee, 0)), 0) AS [Amt]
    FROM #Auth AS n2
    JOIN #OrderNo AS t
        ON n2.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
    JOIN dbo.Orders AS o
        ON n2.Order_No = o.Order_No
    WHERE
        n2.OrderType_ID IN (30, 34)
        AND n2.Filled = 1
        AND n2.Void = 0
    GROUP BY CASE
        WHEN n2.Void = 1
            THEN
                'Void'
        WHEN
            n2.Filled = 1
            AND n2.Void = 0
            THEN
                'Filled'
        ELSE
            'Pending'
    END,
    n2.Order_No,
    n2.DateOrdered,
    n2.AuthNumber;

    IF OBJECT_ID('tempdb..#AuthProcessed') IS NOT NULL
        BEGIN
            DROP TABLE #AuthProcessed;
        END;

    SELECT
        AuthNumber,
        Status,
        SUM(
            CASE
                WHEN
                    GroupType NOT IN ('ChargeBack', 'Rebate')
                    AND Status = 'Filled'
                    THEN
                        Amt
                ELSE
                    0
            END
        ) AS [SumFilled],
        COUNT(
            CASE
                WHEN
                    GroupType NOT IN ('ChargeBack', 'Rebate')
                    AND Status = 'Filled' THEN
                    1
            END
        ) AS [CountFilled],
        SUM(
            CASE
                WHEN
                    GroupType = 'ChargeBack'
                    AND Status = 'Filled'
                    THEN
                        Amt
                ELSE
                    0
            END
        ) AS [SumChargeback],
        COUNT(
            CASE
                WHEN
                    GroupType = 'ChargeBack'
                    AND Status = 'Filled' THEN
                    1
            END
        ) AS [CountChargeback],
        SUM(
            CASE
                WHEN
                    GroupType NOT IN ('ChargeBack', 'Rebate')
                    AND Status = 'Void'
                    THEN
                        Amt
                ELSE
                    0
            END
        ) AS [SumVoid],
        COUNT(
            CASE
                WHEN
                    GroupType NOT IN ('ChargeBack', 'Rebate')
                    AND Status = 'Void' THEN
                    1
            END
        ) AS [CountVoid],
        SUM(
            CASE
                WHEN
                    GroupType NOT IN ('ChargeBack', 'Rebate')
                    AND Status = 'Pending'
                    THEN
                        Amt
                ELSE
                    0
            END
        ) AS [SumPending],
        COUNT(
            CASE
                WHEN
                    GroupType NOT IN ('ChargeBack', 'Rebate')
                    AND Status = 'Pending' THEN
                    1
            END
        ) AS [CountPending],
        SUM(
            CASE
                WHEN GroupType = 'Rebate'
                    THEN
                        Amt
                ELSE
                    0
            END
        ) AS [SumRebate],
        COUNT(
            CASE
                WHEN GroupType = 'Rebate' THEN
                    1
            END
        ) AS [CountRebate]
    INTO #AuthProcessed
    FROM #AuthProcessedV1
    GROUP BY
        AuthNumber,
        Status;

    SELECT
        t.CarrierId,
        t.Carrier_Name,
        COUNT(DISTINCT t.Order_No) AS [Total_Activation],
        CAST(t.DateOrdered AS DATE) AS [Date_Ordered],
        COUNT(
            DISTINCT CASE
                WHEN a.SumFilled = 0 AND a.SumVoid = 0 AND a.CountPending > 0 THEN
                    t.Order_No
            END
        ) AS [Submitted_Activation],
        SUM(
            CASE
                WHEN
                    a.SumFilled = 0
                    AND a.SumVoid = 0
                    AND a.CountPending > 0
                    THEN
                        a.SumPending * (-1)
                ELSE
                    0
            END
        ) AS [Submitted_Activation_Total],
        SUM(a.CountFilled - a.CountChargeback + a.CountRebate) AS [Eligible],
        SUM(
            CASE
                WHEN a.SumFilled + a.SumChargeback + a.SumRebate < 0
                    THEN
                        (a.SumFilled + a.SumChargeback + a.SumRebate) * (-1)
                ELSE
                    0
            END
        ) AS [Eligible_Total],
        SUM(a.CountVoid + a.CountChargeback) AS [Ineligible],
        SUM(a.SumVoid + a.SumChargeback) AS [Ineligible_Total]
    FROM #OrderNo AS t
    LEFT JOIN #AuthProcessed AS a
        ON a.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
    WHERE
        EXISTS
        (
            SELECT 1
            FROM #Auth AS q
            WHERE q.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
        )
        OR EXISTS
        (
            SELECT 1
            FROM #AuthProcessed AS q
            WHERE q.AuthNumber = CAST(t.Order_No AS VARCHAR(MAX))
        )
    GROUP BY
        CAST(t.DateOrdered AS DATE),
        t.CarrierId,
        t.Carrier_Name;

END;
