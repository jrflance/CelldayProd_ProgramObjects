--liquibase formatted sql

--changeset SammerBazerbashi:bfe833d5-e407-44c4-b705-8f06c0daca8a stripComments:false runOnChange:true splitStatements:false

-- noqa: disable=all

-- =============================================
--             :
--      Author : Samer Bazerbashi
--             :
--     Created : 2015-07-20
--             :
-- Description :
--             :
--       Usage : EXEC [Report].[P_Report_Lookup_Chargeback_Related_Orders] 41314603
--             :
--  SB20150827 : Added date columns and product ID
--  CH20160930 : Optimization to render code SARGable and use Index
--  JR20151116 : Trapped for NULL or empty string @OrderNumber
--  SB20160926 : Added RTR activation reporting
--  CH20170112 : Optimization to use integer on orderno INC-66879
--  SB20180522 : Updated to handle new Simple API to use bill item instead of SKU
--  SB20180816 : Updated the 05-22 update.  Pin column for RML does sometimes have data so removed this restriction. Resolved issue with spiff debits.
--  SB20180817 : Added activation spiff back as a commission type
--  SB20201231 : Added fixes for promo ordertypes to keep from duplicating results
--  SB20240228 : Added the Activation Fee item
-- =============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_Lookup_Chargeback_Related_Orders_History]
    (@OrderNumber INT)
AS
BEGIN

BEGIN TRY


    IF ISNULL(@OrderNumber, '') = ''
        BEGIN
            SELECT 'The "OrderNumber" is a required parameter for this report!' AS [Error Message]
            UNION
            SELECT '     Please enter an "OrderNumber" and try again.' AS [Error Message]
            ORDER BY [Error Message] DESC;
            RETURN;
        END;

    DECLARE @orderNumberChar NVARCHAR(50) = CAST(@OrderNumber AS NVARCHAR(50));

    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE
        @originalorder VARCHAR(30),
        @OriginalOrderInt INT; -- V2

    SELECT
        @originalorder =
        (
            SELECT Order_No
            FROM Order_No
            WHERE
                Order_No = @orderNumberChar
                AND OrderType_ID IN (22, 23)
        );

    SET @OriginalOrderInt = @originalorder;

    --if order provided is retrospiff or addtional month get the original activation order
    IF @originalorder IS NULL
        BEGIN
            SET
                @originalorder =
                (
                    SELECT CAST(AuthNumber AS VARCHAR(30))
                    FROM Order_No
                    WHERE
                        Order_No = @orderNumberChar
                        AND OrderType_ID NOT IN (22, 23)
                );
        END;

    --if order provided is an activation or airtime use this as the original order
    IF @originalorder IS NULL
        BEGIN
            SET
                @originalorder =
                (
                    SELECT Order_No FROM Order_No WHERE Order_No = @orderNumberChar
                --AND OrderType_ID IN ( 1, 9 )
                );
        END;

    --check to see if this is the old RTR api order build for activations or airtime
    IF
        (
            SELECT DISTINCT
                TXN_GROUP
            FROM Tracfone.tblTSPTransactionFeed
            WHERE Order_No = @originalorder
        ) = 'rtr'
        --(
        --    SELECT p.Product_Type
        --    FROM Order_PO_Detail pod
        --        LEFT JOIN Products p
        --            ON p.Product_ID = pod.Vendor_SKU
        --        JOIN Order_No o
        --            ON o.Order_No = @OriginalOrderInt
        --               AND o.OrderType_ID IN ( 22, 23 ) -- V2
        --    WHERE pod.Order_No = @originalorder
        --) = 1
        --OR
        --(
        --    SELECT p.Product_Type
        --    FROM Order_PO_Detail pod
        --        LEFT JOIN Products p
        --            ON p.Product_ID = pod.Product_ID
        --        JOIN Order_No o
        --            ON o.Order_No = @OrderNumber
        --               AND o.OrderType_ID IN ( 1, 9 ) -- V2
        --    WHERE pod.Order_No = @orderNumberChar
        --) = 1
        BEGIN
            DECLARE @vendororder VARCHAR(30);

            SELECT @vendororder = po.Vendor_Order_No
            FROM Order_PO_Detail AS pod
            LEFT JOIN Order_PO AS po
                ON po.Order_PO_ID = pod.Order_PO_ID
            WHERE Order_No = @originalorder;

            DECLARE
                @tspID VARCHAR(30),
                @sku VARCHAR(30);

            SELECT @tspID = Account_ID
            FROM Order_No
            WHERE Order_No = @originalorder;

            SELECT @sku = CAST(SKU AS VARCHAR(30))
            FROM Orders
            WHERE
                Order_No = @originalorder
                AND ParentItemID = 0;



            IF OBJECT_ID('tempdb..#celldayhistory') IS NOT NULL
                BEGIN
                    DROP TABLE #celldayhistory;
                END;

            SELECT *
            INTO #celldayhistory
            FROM CellDay_History.Tracfone.tblDealerCommissionDetail
            WHERE
                RTR_TXN_REFERENCE1 = @sku
                AND TSP_ID = @tspID
                AND
                (
                    PIN = ''
                    OR PIN IS NULL
                );



            IF OBJECT_ID('tempdb..#Tmp1') IS NOT NULL
                BEGIN
                    DROP TABLE #Tmp1;
                END;

            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                a.AuthNumber AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                (
                    SELECT CONCAT('PromoID: ', o1.Dropship_Qty, ' - PID: ', oo1.Product_ID, ' - ', p2.Name)
                    FROM Order_No AS oo WITH (INDEX (PK_ORDER_NO))
                    JOIN dbo.Orders AS oo1
                        ON oo1.Order_No = oo.Order_No
                    JOIN dbo.Products AS p2
                        ON p2.Product_ID = oo1.Product_ID
                    JOIN dbo.tblOrderItemAddons AS toia2 WITH (INDEX (IX_tblOrderItemAddons_AddonsValue))
                        ON
                            toia2.OrderID = oo1.ID
                            AND toia2.AddonsValue = toia.AddonsValue
                    JOIN dbo.tblAddonFamily AS taf WITH (INDEX (IX_tblAddonFamily_AddonId))
                        ON
                            taf.AddonID = toia2.AddonsID
                            AND taf.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                    WHERE
                        oo.OrderType_ID IN (57, 58)
                        AND oo.Account_ID = o.Account_ID
                ) AS RTR_TXN_REFERENCE1,
                o.DateOrdered AS TcetraOrderDate,
                o.DateFilled AS TcetraFilledDate,
                o.DateDue AS TcetraDueDate,
                o.Filled,
                o.Process,
                o.Void
            INTO #Tmp1
            FROM
                (
                    SELECT
                        Order_No,
                        AuthNumber
                    FROM Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE AuthNumber = @originalorder
                ) AS a
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON
                    a.Order_No = o.Order_No
                    AND o.OrderType_ID IN (59, 60)
            JOIN dbo.Orders AS o1
                ON
                    o1.Order_No = a.Order_No
                    AND o1.Product_ID = 6084
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            JOIN dbo.tblOrderItemAddons AS toia WITH (INDEX (IX_tblOrderItemAddons_OrderId))
                ON toia.OrderID = o1.ID
            JOIN dbo.tblAddonFamily AS taf2 WITH (INDEX (IX_tblAddonFamily_AddonId))
                ON
                    taf2.AddonID = toia.AddonsID
                    AND taf2.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
            UNION
            SELECT DISTINCT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                a.AuthNumber AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU AS RTR_TXN_REFERENCE1,
                o.DateOrdered AS TcetraOrderDate,
                o.DateFilled AS TcetraFilledDate,
                o.DateDue AS TcetraDueDate,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT
                        Order_No,
                        AuthNumber
                    FROM Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE AuthNumber = @originalorder
                ) AS a
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON a.Order_No = o.Order_No
            JOIN dbo.Orders AS o1
                ON
                    o1.Order_No = a.Order_No
                    AND o1.Product_ID != 6084
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                (
                    SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                ) AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU AS RTR_TXN_REFERENCE1,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM Order_No AS o WITH (INDEX (PK_ORDER_NO))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            LEFT JOIN dbo.tblOrderItemAddons AS toia
                ON toia.AddonsID = o1.ID
            WHERE o.Order_No = @originalorder
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                '' AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                NULL AS SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM Order_No AS o WITH (INDEX (PK_ORDER_NO))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON
                    p.Product_ID = o1.Product_ID
                    AND p.Product_Type = 17
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            WHERE o.Order_No = @originalorder
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS Authnumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU AS RTR_TXN_REFERENCE1,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT AuthNumber
                    FROM dbo.Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE Order_No = @originalorder
                ) AS a
            JOIN dbo.Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON o.Order_No = cast (a.AuthNumber AS INT)
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            LEFT JOIN dbo.tblOrderItemAddons AS toia
                ON toia.AddonsID = o1.ID
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS AuthNumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU AS RTR_TXN_REFERENCE1,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT o.Order_No
                    FROM
                        (
                            SELECT AuthNumber
                            FROM dbo.Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                            WHERE Order_No = @originalorder
                        ) AS a
                    JOIN dbo.Order_No AS o
                        ON o.Order_No = cast (a.AuthNumber AS INT)
                ) AS b
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON o.AuthNumber = cast (b.Order_No AS NVARCHAR(50))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            LEFT JOIN dbo.tblOrderItemAddons AS toia
                ON toia.AddonsID = o1.ID;


            IF OBJECT_ID('tempdb..#allresults1') IS NOT NULL
                BEGIN
                    DROP TABLE #allresults1;
                END;


            SELECT
                Order_No,
                Product_ID,
                OrderType_Desc,
                ActivationOrder,
                coalesce (dcd.TSP_ID, Account_ID) AS Account_ID,
                Account_Name,
                AccountType_Desc,
                Price,
                Name,
                t.RTR_TXN_REFERENCE1 + '-' + CAST(@vendororder AS VARCHAR(30)) AS RTR_TXN_REFERENCE1,
                dcd.SIM,
                dcd.ESN,
                dcd.COMMISSION_AMOUNT AS COMMISSION_AMOUNT,
                dcd.COMMISSION_TYPE,
                dcd.NON_COMMISSIONED_REASON,
                dcd.Create_Date AS SpiffResponseDate,
                TcetraOrderDate,
                TcetraFilledDate,
                TcetraDueDate,
                Filled,
                Process,
                Void,
                ROW_NUMBER() OVER (
                    PARTITION BY Order_No,
                    Product_ID
                    ORDER BY
                        dcd.COMMISSION_AMOUNT DESC,
                        dcd.Create_Date DESC
                ) AS Rnum
            INTO #allresults1
            FROM #Tmp1 AS t
            LEFT JOIN CellDay_History.Tracfone.tblDealerCommissionDetail AS dcd WITH (INDEX (IX_tracfone_tblDealerCommissionDetail_RTRRefTspId))
                ON (
                    (
                        dcd.RTR_TXN_REFERENCE1 = cast (t.RTR_TXN_REFERENCE1 AS VARCHAR(25))
                        AND CAST(dcd.TSP_ID AS VARCHAR(30)) IN
                        (
                            SELECT CAST(@tspID AS VARCHAR(30)) AS AccountID
                            UNION
                            SELECT PaymentAccountID AS AccountID
                            FROM Operations.tblResidualType
                            WHERE ISNULL(PaymentAccountID, 0) != 0
                            UNION
                            SELECT C_StoreOverrideAccount AS AccountID
                            FROM Operations.tblResidualType
                            WHERE ISNULL(C_StoreOverrideAccount, 0) != 0
                        )
                    )
                    AND dcd.RTR_TXN_REFERENCE1 <> ''
                    AND OrderType_Desc NOT IN (
                        'Retroactive Prepaid Spiff', 'Retroactive Postpaid Spiff',
                        'PostPaid Additional Spiff', 'PrePaid Additional Spiff',
                        'Spiff Debit Order', 'Postpaid Promo Order', 'Prepaid Promo Order'
                    )
                    AND dcd.COMMISSION_TYPE IN
                    (
                        SELECT 'ACTIVATION SPIFF' AS CommissionType
                        UNION
                        SELECT DISTINCT
                            CommissionType
                        FROM Tracfone.tblCarrierCommissionProductMapping
                        UNION
                        SELECT ResidualType
                        FROM Operations.tblResidualType
                    )
                )
            GROUP BY
                Order_No,
                Product_ID,
                OrderType_Desc,
                ActivationOrder,
                Account_ID,
                dcd.TSP_ID,
                Account_Name,
                AccountType_Desc,
                Price,
                Name,
                t.RTR_TXN_REFERENCE1,
                dcd.SIM,
                dcd.ESN,
                dcd.COMMISSION_AMOUNT,
                dcd.NON_COMMISSIONED_REASON,
                dcd.Create_Date,
                TcetraOrderDate,
                TcetraFilledDate,
                TcetraDueDate,
                Filled,
                Process,
                Void,
                dcd.DealerCommissionDetailID,
                dcd.COMMISSION_TYPE
            ORDER BY
                dcd.COMMISSION_AMOUNT DESC,
                dcd.Create_Date DESC;


            --select * from #allresults

            IF OBJECT_ID('tempdb..#all0commission1') IS NOT NULL
                BEGIN
                    DROP TABLE #all0commission1;
                END;


            SELECT *
            INTO #all0commission1
            FROM #allresults1
            WHERE COMMISSION_AMOUNT = '0';


            IF OBJECT_ID('tempdb..#final1') IS NOT NULL
                BEGIN
                    DROP TABLE #final1;
                END;

            WITH TopCategoryArticles AS (
                SELECT
                    Rnum AS Rnum1,
                    ROW_NUMBER() OVER (PARTITION BY RTR_TXN_REFERENCE1 ORDER BY SpiffResponseDate DESC) AS [Order]
                FROM #all0commission1
                WHERE COMMISSION_AMOUNT = '0'
            )
            SELECT *
            INTO #final1
            FROM TopCategoryArticles AS tca
            LEFT JOIN #all0commission1 AS a
                ON tca.Rnum1 = a.Rnum
            WHERE tca.[Order] = 1;

            SELECT
                a.Order_No,
                a.Product_ID,
                a.OrderType_Desc,
                a.ActivationOrder,
                a.Account_ID,
                a2.Account_Name,
                a.AccountType_Desc,
                a.Price,
                a.Name,
                a.RTR_TXN_REFERENCE1,
                a.SIM,
                a.ESN,
                a.COMMISSION_AMOUNT,
                a.COMMISSION_TYPE,
                a.NON_COMMISSIONED_REASON,
                a.SpiffResponseDate,
                a.TcetraOrderDate,
                a.TcetraFilledDate,
                a.TcetraDueDate,
                a.Filled,
                a.Process,
                a.Void,
                a.Rnum
            FROM
                (
                    SELECT
                        Order_No,
                        Product_ID,
                        OrderType_Desc,
                        ActivationOrder,
                        Account_ID,
                        Account_Name,
                        AccountType_Desc,
                        Price,
                        Name,
                        RTR_TXN_REFERENCE1,
                        SIM,
                        ESN,
                        COMMISSION_AMOUNT,
                        COMMISSION_TYPE,
                        NON_COMMISSIONED_REASON,
                        SpiffResponseDate,
                        TcetraOrderDate,
                        TcetraFilledDate,
                        TcetraDueDate,
                        Filled,
                        Process,
                        Void,
                        Rnum
                    FROM #allresults1
                    WHERE
                        COMMISSION_AMOUNT != '0'
                        AND AccountType_Desc != 'Vendor'
                    UNION
                    SELECT
                        Order_No,
                        Product_ID,
                        OrderType_Desc,
                        ActivationOrder,
                        Account_ID,
                        Account_Name,
                        AccountType_Desc,
                        Price,
                        Name,
                        RTR_TXN_REFERENCE1,
                        SIM,
                        ESN,
                        COMMISSION_AMOUNT,
                        COMMISSION_TYPE,
                        NON_COMMISSIONED_REASON,
                        SpiffResponseDate,
                        TcetraOrderDate,
                        TcetraFilledDate,
                        TcetraDueDate,
                        Filled,
                        Process,
                        Void,
                        Rnum
                    FROM #allresults1
                    WHERE
                        Rnum = 1
                        AND AccountType_Desc != 'Vendor'
                    UNION
                    SELECT
                        f.Order_No,
                        f.Product_ID,
                        f.OrderType_Desc,
                        f.ActivationOrder,
                        f.Account_ID,
                        f.Account_Name,
                        f.AccountType_Desc,
                        f.Price,
                        f.Name,
                        f.RTR_TXN_REFERENCE1,
                        f.SIM,
                        f.ESN,
                        f.COMMISSION_AMOUNT,
                        f.COMMISSION_TYPE,
                        f.NON_COMMISSIONED_REASON,
                        f.SpiffResponseDate,
                        f.TcetraOrderDate,
                        f.TcetraFilledDate,
                        f.TcetraDueDate,
                        f.Filled,
                        f.Process,
                        f.Void,
                        f.Rnum
                    FROM #final1 AS f
                    WHERE AccountType_Desc != 'Vendor'
                ) AS a
            JOIN dbo.Account AS a2
                ON a2.Account_ID = a.Account_ID
            ORDER BY
                Order_No ASC,
                SpiffResponseDate DESC,
                COMMISSION_AMOUNT DESC,
                Rnum DESC,
                TcetraFilledDate ASC,
                TcetraOrderDate ASC;



        END;

    ELSE IF
        EXISTS
        (
            (
                SELECT 1
                FROM dbo.tblOrderItemAddons
                WHERE
                    AddonsID = 196
                    AND OrderID IN
                    (
                        SELECT ID FROM Orders WHERE Order_No = @originalorder AND ParentItemID = 0
                    )
            )
            UNION
            SELECT 1
            FROM dbo.tblOrderItemAddons
            WHERE
                AddonsID = 196
                AND OrderID =
                (
                    SELECT ID
                    FROM Orders AS o1
                    JOIN Order_No AS o
                        ON
                            o.Order_No = o1.Order_No
                            AND o.OrderType_ID IN (1, 9)
                    WHERE o.Order_No = @orderNumberChar
                )
        )
        BEGIN


            DECLARE @tspID3 VARCHAR(30);

            SELECT @tspID3 = Account_ID
            FROM Order_No
            WHERE Order_No = @originalorder;

            IF OBJECT_ID('tempdb..#Tmp0') IS NOT NULL
                BEGIN
                    DROP TABLE #Tmp0;
                END;


            SELECT DISTINCT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                a.AuthNumber AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                (
                    SELECT CONCAT('PromoID: ', o1.Dropship_Qty, ' - PID: ', oo1.Product_ID, ' - ', p2.Name)
                    FROM Order_No AS oo WITH (INDEX (PK_ORDER_NO))
                    JOIN dbo.Orders AS oo1
                        ON oo1.Order_No = oo.Order_No
                    JOIN dbo.Products AS p2
                        ON p2.Product_ID = oo1.Product_ID
                    JOIN dbo.tblOrderItemAddons AS toia2 WITH (INDEX (IX_tblOrderItemAddons_AddonsValue))
                        ON
                            toia2.OrderID = oo1.ID
                            AND toia2.AddonsValue = toia.AddonsValue
                    JOIN dbo.tblAddonFamily AS taf WITH (INDEX (IX_tblAddonFamily_AddonId))
                        ON
                            taf.AddonID = toia2.AddonsID
                            AND taf.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                    WHERE
                        oo.OrderType_ID IN (57, 58)
                        AND oo.Account_ID = o.Account_ID
                ) AS SKU,
                o.DateOrdered AS TcetraOrderDate,
                o.DateFilled AS TcetraFilledDate,
                o.DateDue AS TcetraDueDate,
                o.Filled,
                o.Process,
                o.Void
            INTO #Tmp0
            FROM
                (
                    SELECT
                        Order_No,
                        AuthNumber
                    FROM Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE AuthNumber = @originalorder
                ) AS a
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON
                    a.Order_No = o.Order_No
                    AND o.OrderType_ID IN (59, 60)
            JOIN dbo.Orders AS o1
                ON
                    o1.Order_No = a.Order_No
                    AND o1.Product_ID = 6084
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            JOIN dbo.tblOrderItemAddons AS toia WITH (INDEX (IX_tblOrderItemAddons_OrderId))
                ON toia.OrderID = o1.ID
            JOIN dbo.tblAddonFamily AS taf2 WITH (INDEX (IX_tblAddonFamily_AddonId))
                ON
                    taf2.AddonID = toia.AddonsID
                    AND taf2.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
            UNION
            SELECT DISTINCT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                a.AuthNumber AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered AS TcetraOrderDate,
                o.DateFilled AS TcetraFilledDate,
                o.DateDue AS TcetraDueDate,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT
                        Order_No,
                        AuthNumber
                    FROM Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE AuthNumber = @originalorder
                ) AS a
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON a.Order_No = o.Order_No
            JOIN dbo.Orders AS o1
                ON
                    o1.Order_No = a.Order_No
                    AND o1.Product_ID != 6084
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                (
                    SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                ) AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                CASE
                    WHEN o1.ParentItemID = 0
                        THEN
                            toia.AddonsValue
                    ELSE
                        NULL
                END AS SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM Order_No AS o WITH (INDEX (PK_ORDER_NO))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            JOIN dbo.tblOrderItemAddons AS toia
                ON
                    toia.OrderID = o1.ID
                    AND toia.AddonsID = 196
            LEFT JOIN dbo.tblOrderItemAddons AS toia3
                ON toia.AddonsID = o1.ID
            WHERE o.Order_No = @originalorder
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                '' AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                NULL AS SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM Order_No AS o WITH (INDEX (PK_ORDER_NO))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON
                    p.Product_ID = o1.Product_ID
                    AND p.Product_Type = 17
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            WHERE o.Order_No = @originalorder
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS AuthNumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT AuthNumber
                    FROM dbo.Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE Order_No = @originalorder
                ) AS a
            JOIN dbo.Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON o.Order_No = cast (a.AuthNumber AS INT)
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            LEFT JOIN dbo.tblOrderItemAddons AS toia
                ON toia.AddonsID = o1.ID
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS AuthNumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT o.Order_No
                    FROM
                        (
                            SELECT AuthNumber
                            FROM dbo.Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                            WHERE Order_No = @originalorder
                        ) AS a
                    JOIN dbo.Order_No AS o
                        ON o.Order_No = cast (a.AuthNumber AS INT)
                ) AS b
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON o.AuthNumber = cast (b.Order_No AS NVARCHAR(50))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            LEFT JOIN dbo.tblOrderItemAddons AS toia
                ON toia.AddonsID = o1.ID;

            IF OBJECT_ID('tempdb..#allresults0') IS NOT NULL
                BEGIN
                    DROP TABLE #allresults0;
                END;
            WITH cte AS (
                SELECT CAST(@tspID3 AS VARCHAR(30)) AS AccountID
                UNION
                SELECT PaymentAccountID AS AccountID
                FROM Operations.tblResidualType
                WHERE ISNULL(PaymentAccountID, 0) != 0
                UNION
                SELECT C_StoreOverrideAccount AS AccountID
                FROM Operations.tblResidualType
                WHERE ISNULL(C_StoreOverrideAccount, 0) != 0
            )

            --select * from #tmp0



            SELECT
                Order_No,
                Product_ID,
                OrderType_Desc,
                ActivationOrder,
                coalesce (dcd.TSP_ID, Account_ID) AS Account_ID,
                Account_Name,
                AccountType_Desc,
                Price,
                Name,
                SKU,
                dcd.SIM,
                dcd.ESN,
                dcd.COMMISSION_AMOUNT AS COMMISSION_AMOUNT,
                dcd.COMMISSION_TYPE,
                dcd.NON_COMMISSIONED_REASON,
                dcd.Create_Date AS SpiffResponseDate,
                TcetraOrderDate,
                TcetraFilledDate,
                TcetraDueDate,
                Filled,
                Process,
                Void,
                ROW_NUMBER() OVER (
                    PARTITION BY Order_No,
                    Product_ID
                    ORDER BY
                        dcd.COMMISSION_AMOUNT DESC,
                        dcd.Create_Date DESC
                ) AS Rnum
            INTO #allresults0
            FROM #Tmp0
            LEFT JOIN CellDay_History.Tracfone.tblDealerCommissionDetail AS dcd WITH (INDEX (IX_tracfone_tblDealerCommissionDetail_RTRRefTspId))
                ON
                    dcd.RTR_TXN_REFERENCE1 = cast (SKU AS VARCHAR(50))
                    AND SKU != ''
                    AND dcd.TSP_ID IN
                    (
                        SELECT AccountID FROM cte
                    )
                    AND OrderType_Desc NOT IN (
                        'Retroactive Prepaid Spiff', 'Retroactive Postpaid Spiff',
                        'PostPaid Additional Spiff', 'PrePaid Additional Spiff',
                        'Spiff Debit Order', 'Postpaid Promo Order', 'Prepaid Promo Order'
                    )
                    AND dcd.COMMISSION_TYPE IN
                    (
                        SELECT 'ACTIVATION SPIFF' AS CommissionType
                        UNION
                        SELECT DISTINCT
                            CommissionType
                        FROM Tracfone.tblCarrierCommissionProductMapping
                        UNION
                        SELECT ResidualType
                        FROM Operations.tblResidualType
                    )
            GROUP BY
                Order_No,
                Product_ID,
                OrderType_Desc,
                ActivationOrder,
                Account_ID,
                dcd.TSP_ID,
                Account_Name,
                AccountType_Desc,
                Price,
                Name,
                SKU,
                dcd.SIM,
                dcd.ESN,
                dcd.COMMISSION_AMOUNT,
                dcd.NON_COMMISSIONED_REASON,
                dcd.Create_Date,
                TcetraOrderDate,
                TcetraFilledDate,
                TcetraDueDate,
                Filled,
                Process,
                Void,
                dcd.DealerCommissionDetailID,
                dcd.COMMISSION_TYPE
            ORDER BY
                dcd.COMMISSION_AMOUNT DESC,
                dcd.Create_Date DESC;


                --select * from #allresults

            IF OBJECT_ID('tempdb..#all0commission0') IS NOT NULL
                BEGIN
                    DROP TABLE #all0commission0;
                END;

            SELECT *
            INTO #all0commission0
            FROM #allresults0
            WHERE COMMISSION_AMOUNT = '0';


            IF OBJECT_ID('tempdb..#final0') IS NOT NULL
                BEGIN
                    DROP TABLE #final0;
                END;


            WITH TopCategoryArticles AS (
                SELECT
                    Rnum AS Rnum1,
                    ROW_NUMBER() OVER (PARTITION BY SKU ORDER BY SpiffResponseDate DESC) AS [Order]
                FROM #all0commission0
                WHERE COMMISSION_AMOUNT = '0'
            )
            SELECT *
            INTO #final0
            FROM TopCategoryArticles AS tca
            LEFT JOIN #all0commission0 AS a
                ON tca.Rnum1 = a.Rnum
            WHERE tca.[Order] = 1;


            SELECT
                a.Order_No,
                a.Product_ID,
                a.OrderType_Desc,
                a.ActivationOrder,
                a.Account_ID,
                a2.Account_Name,
                a.AccountType_Desc,
                a.Price,
                a.Name,
                a.SKU,
                a.SIM,
                a.ESN,
                a.COMMISSION_AMOUNT,
                a.COMMISSION_TYPE,
                a.NON_COMMISSIONED_REASON,
                a.SpiffResponseDate,
                a.TcetraOrderDate,
                a.TcetraFilledDate,
                a.TcetraDueDate,
                a.Filled,
                a.Process,
                a.Void,
                a.Rnum
            FROM
                (
                    SELECT
                        Order_No,
                        Product_ID,
                        OrderType_Desc,
                        ActivationOrder,
                        Account_ID,
                        Account_Name,
                        AccountType_Desc,
                        Price,
                        Name,
                        SKU,
                        SIM,
                        ESN,
                        COMMISSION_AMOUNT,
                        COMMISSION_TYPE,
                        NON_COMMISSIONED_REASON,
                        SpiffResponseDate,
                        TcetraOrderDate,
                        TcetraFilledDate,
                        TcetraDueDate,
                        Filled,
                        Process,
                        Void,
                        Rnum
                    FROM #allresults0
                    WHERE
                        COMMISSION_AMOUNT != '0'
                        AND AccountType_Desc != 'Vendor'
                    UNION
                    SELECT
                        Order_No,
                        Product_ID,
                        OrderType_Desc,
                        ActivationOrder,
                        Account_ID,
                        Account_Name,
                        AccountType_Desc,
                        Price,
                        Name,
                        SKU,
                        SIM,
                        ESN,
                        COMMISSION_AMOUNT,
                        COMMISSION_TYPE,
                        NON_COMMISSIONED_REASON,
                        SpiffResponseDate,
                        TcetraOrderDate,
                        TcetraFilledDate,
                        TcetraDueDate,
                        Filled,
                        Process,
                        Void,
                        Rnum
                    FROM #allresults0
                    WHERE
                        Rnum = 1
                        AND AccountType_Desc != 'Vendor'
                    UNION
                    SELECT
                        f.Order_No,
                        f.Product_ID,
                        f.OrderType_Desc,
                        f.ActivationOrder,
                        f.Account_ID,
                        f.Account_Name,
                        f.AccountType_Desc,
                        f.Price,
                        f.Name,
                        f.SKU,
                        f.SIM,
                        f.ESN,
                        f.COMMISSION_AMOUNT,
                        f.COMMISSION_TYPE,
                        f.NON_COMMISSIONED_REASON,
                        f.SpiffResponseDate,
                        f.TcetraOrderDate,
                        f.TcetraFilledDate,
                        f.TcetraDueDate,
                        f.Filled,
                        f.Process,
                        f.Void,
                        f.Rnum
                    FROM #final0 AS f
                    WHERE AccountType_Desc != 'Vendor'
                ) AS a
            JOIN dbo.Account AS a2
                ON a2.Account_ID = a.Account_ID
            ORDER BY
                Order_No ASC,
                SpiffResponseDate DESC,
                COMMISSION_AMOUNT DESC,
                Rnum DESC,
                TcetraFilledDate ASC,
                TcetraOrderDate ASC;


        END;



    ELSE


        --this must be a pin based activation
        BEGIN


            DECLARE
                @tspID2 VARCHAR(30),
                @sku2 VARCHAR(30);

            SELECT @tspID2 = Account_ID
            FROM Order_No
            WHERE Order_No = @originalorder;

            SELECT @sku2 = CAST(SKU AS VARCHAR(30))
            FROM Orders
            WHERE
                Order_No = @originalorder
                AND ParentItemID = 0;

            IF OBJECT_ID('tempdb..#Tmp') IS NOT NULL
                BEGIN
                    DROP TABLE #Tmp;
                END;


            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                a.AuthNumber AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                (
                    SELECT CONCAT('PromoID: ', o1.Dropship_Qty, ' - PID: ', oo1.Product_ID, ' - ', p2.Name)
                    FROM Order_No AS oo WITH (INDEX (PK_ORDER_NO))
                    JOIN dbo.Orders AS oo1
                        ON oo1.Order_No = oo.Order_No
                    JOIN dbo.Products AS p2
                        ON p2.Product_ID = oo1.Product_ID
                    JOIN dbo.tblOrderItemAddons AS toia2 WITH (INDEX (IX_tblOrderItemAddons_AddonsValue))
                        ON
                            toia2.OrderID = oo1.ID
                            AND toia2.AddonsValue = toia.AddonsValue
                    JOIN dbo.tblAddonFamily AS taf WITH (INDEX (IX_tblAddonFamily_AddonId))
                        ON
                            taf.AddonID = toia2.AddonsID
                            AND taf.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
                    WHERE
                        oo.OrderType_ID IN (57, 58)
                        AND oo.Account_ID = o.Account_ID
                ) AS SKU,
                o.DateOrdered AS TcetraOrderDate,
                o.DateFilled AS TcetraFilledDate,
                o.DateDue AS TcetraDueDate,
                o.Filled,
                o.Process,
                o.Void
            INTO #Tmp
            FROM
                (
                    SELECT
                        Order_No,
                        AuthNumber
                    FROM Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE AuthNumber = @originalorder
                ) AS a
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON
                    a.Order_No = o.Order_No
                    AND o.OrderType_ID IN (59, 60)
            JOIN dbo.Orders AS o1
                ON
                    o1.Order_No = a.Order_No
                    AND o1.Product_ID = 6084
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            JOIN dbo.tblOrderItemAddons AS toia WITH (INDEX (IX_tblOrderItemAddons_OrderId))
                ON toia.OrderID = o1.ID
            JOIN dbo.tblAddonFamily AS taf2 WITH (INDEX (IX_tblAddonFamily_AddonId))
                ON
                    taf2.AddonID = toia.AddonsID
                    AND taf2.AddonTypeName IN ('DeviceBYOPType', 'DeviceType')
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                a.AuthNumber AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered AS TcetraOrderDate,
                o.DateFilled AS TcetraFilledDate,
                o.DateDue AS TcetraDueDate,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT
                        Order_No,
                        AuthNumber
                    FROM Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE AuthNumber = @originalorder
                ) AS a
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON a.Order_No = o.Order_No
            JOIN dbo.Orders AS o1
                ON
                    o1.Order_No = a.Order_No
                    AND o1.Product_ID != 6084
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            WHERE o1.Product_ID != 6084
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS AuthNumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM Order_No AS o WITH (INDEX (PK_ORDER_NO))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            WHERE o.Order_No = @originalorder
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                '' AS ActivationOrder,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                NULL AS SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM Order_No AS o WITH (INDEX (PK_ORDER_NO))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON
                    p.Product_ID = o1.Product_ID
                    AND p.Product_Type = 17
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            WHERE o.Order_No = @originalorder
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS AuthNumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT AuthNumber
                    FROM dbo.Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                    WHERE Order_No = @originalorder
                ) AS a
            JOIN dbo.Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON o.Order_No = cast (a.AuthNumber AS INT)
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID
            UNION
            SELECT
                o.Order_No,
                o1.Product_ID,
                ot.OrderType_Desc,
                CASE
                    WHEN o.OrderType_ID IN (22, 23)
                        THEN
                            (
                                SELECT o1.Dropship_Note WHERE o1.ParentItemID = 0
                            )
                    ELSE
                        o.AuthNumber
                END AS AuthNumber,
                o.Account_ID,
                a1.Account_Name,
                at.AccountType_Desc,
                ISNULL(o1.Price, 0) - ISNULL(o1.DiscAmount, 0) + ISNULL(o1.Fee, 0) AS Price,
                p.Name,
                o1.SKU,
                o.DateOrdered,
                o.DateFilled,
                o.DateDue,
                o.Filled,
                o.Process,
                o.Void
            FROM
                (
                    SELECT o.Order_No
                    FROM
                        (
                            SELECT AuthNumber
                            FROM dbo.Order_No WITH (INDEX (IX_OrderNo_AuthNumber))
                            WHERE Order_No = @originalorder
                        ) AS a
                    JOIN dbo.Order_No AS o WITH (INDEX (PK_ORDER_NO))
                        ON o.Order_No = cast (a.AuthNumber AS INT)
                ) AS b
            JOIN Order_No AS o WITH (INDEX (PK_ORDER_NO))
                ON o.AuthNumber = cast (b.Order_No AS NVARCHAR(50))
            JOIN dbo.Orders AS o1
                ON o1.Order_No = o.Order_No
            JOIN dbo.OrderType_ID AS ot
                ON ot.OrderType_ID = o.OrderType_ID
            JOIN dbo.Products AS p
                ON p.Product_ID = o1.Product_ID
            JOIN dbo.Account AS a1
                ON a1.Account_ID = o.Account_ID
            JOIN dbo.AccountType_ID AS at
                ON at.AccountType_ID = a1.AccountType_ID;


            --select * from #tmp
            IF OBJECT_ID('tempdb..#allresults') IS NOT NULL
                BEGIN
                    DROP TABLE #allresults;
                END;

            ;
            WITH cte AS (
                SELECT CAST(@tspID2 AS VARCHAR(30)) AS AccountID
                UNION
                SELECT PaymentAccountID AS AccountID
                FROM Operations.tblResidualType
                WHERE ISNULL(PaymentAccountID, 0) != 0
                UNION
                SELECT C_StoreOverrideAccount AS AccountID
                FROM Operations.tblResidualType
                WHERE ISNULL(C_StoreOverrideAccount, 0) != 0
            )
            SELECT
                Order_No,
                Product_ID,
                OrderType_Desc,
                ActivationOrder,
                coalesce (dcd.TSP_ID, Account_ID) AS Account_ID,
                Account_Name,
                AccountType_Desc,
                Price,
                Name,
                SKU,
                dcd.SIM,
                dcd.ESN,
                dcd.COMMISSION_AMOUNT AS COMMISSION_AMOUNT,
                dcd.COMMISSION_TYPE,
                dcd.NON_COMMISSIONED_REASON,
                dcd.Create_Date AS SpiffResponseDate,
                TcetraOrderDate,
                TcetraFilledDate,
                TcetraDueDate,
                Filled,
                Process,
                Void,
                ROW_NUMBER() OVER (
                    PARTITION BY Order_No,
                    Product_ID
                    ORDER BY
                        dcd.COMMISSION_AMOUNT DESC,
                        dcd.Create_Date DESC
                ) AS Rnum
            INTO #allresults
            FROM #Tmp
            LEFT JOIN CellDay_History.Tracfone.tblDealerCommissionDetail AS dcd
                ON
                    dcd.PIN = cast (SKU AS VARCHAR(50))
                    AND SKU != ''
                    AND dcd.TSP_ID IN
                    (
                        SELECT AccountID FROM cte
                    )
                    AND dcd.PIN <> ''
                    AND OrderType_Desc NOT IN (
                        'Retroactive Prepaid Spiff', 'Retroactive Postpaid Spiff',
                        'PostPaid Additional Spiff', 'PrePaid Additional Spiff',
                        'Spiff Debit Order', 'Postpaid Promo Order', 'Prepaid Promo Order'
                    )
                    AND dcd.COMMISSION_TYPE IN
                    (
                        SELECT 'ACTIVATION SPIFF' AS CommissionType
                        UNION
                        SELECT DISTINCT
                            CommissionType
                        FROM Tracfone.tblCarrierCommissionProductMapping
                        UNION
                        SELECT ResidualType
                        FROM Operations.tblResidualType
                    )
            GROUP BY
                Order_No,
                Product_ID,
                OrderType_Desc,
                ActivationOrder,
                Account_ID,
                dcd.TSP_ID,
                Account_Name,
                AccountType_Desc,
                Price,
                Name,
                SKU,
                dcd.SIM,
                dcd.ESN,
                dcd.COMMISSION_AMOUNT,
                dcd.NON_COMMISSIONED_REASON,
                dcd.Create_Date,
                TcetraOrderDate,
                TcetraFilledDate,
                TcetraDueDate,
                Filled,
                Process,
                Void,
                dcd.DealerCommissionDetailID,
                dcd.COMMISSION_TYPE
            ORDER BY
                dcd.COMMISSION_AMOUNT DESC,
                dcd.Create_Date DESC;


            --select * from #allresults

            IF OBJECT_ID('tempdb..#all0commission') IS NOT NULL
                BEGIN
                    DROP TABLE #all0commission;
                END;


            SELECT *
            INTO #all0commission
            FROM #allresults
            WHERE COMMISSION_AMOUNT = '0';


            IF OBJECT_ID('tempdb..#final') IS NOT NULL
                BEGIN
                    DROP TABLE #final;
                END;

            WITH TopCategoryArticles AS (
                SELECT
                    Rnum AS Rnum1,
                    ROW_NUMBER() OVER (PARTITION BY SKU ORDER BY SpiffResponseDate DESC) AS [Order]
                FROM #all0commission
                WHERE COMMISSION_AMOUNT = '0'
            )
            SELECT *
            INTO #final
            FROM TopCategoryArticles AS tca
            LEFT JOIN #all0commission AS a
                ON tca.Rnum1 = a.Rnum
            WHERE tca.[Order] = 1;


            SELECT
                a.Order_No,
                a.Product_ID,
                a.OrderType_Desc,
                a.ActivationOrder,
                a.Account_ID,
                a2.Account_Name,
                a.AccountType_Desc,
                a.Price,
                a.Name,
                a.SKU,
                a.SIM,
                a.ESN,
                a.COMMISSION_AMOUNT,
                a.COMMISSION_TYPE,
                a.NON_COMMISSIONED_REASON,
                a.SpiffResponseDate,
                a.TcetraOrderDate,
                a.TcetraFilledDate,
                a.TcetraDueDate,
                a.Filled,
                a.Process,
                a.Void,
                a.Rnum
            FROM
                (
                    SELECT
                        Order_No,
                        Product_ID,
                        OrderType_Desc,
                        ActivationOrder,
                        Account_ID,
                        Account_Name,
                        AccountType_Desc,
                        Price,
                        Name,
                        SKU,
                        SIM,
                        ESN,
                        COMMISSION_AMOUNT,
                        COMMISSION_TYPE,
                        NON_COMMISSIONED_REASON,
                        SpiffResponseDate,
                        TcetraOrderDate,
                        TcetraFilledDate,
                        TcetraDueDate,
                        Filled,
                        Process,
                        Void,
                        Rnum
                    FROM #allresults
                    WHERE
                        COMMISSION_AMOUNT != '0'
                        AND AccountType_Desc != 'Vendor'
                    UNION
                    SELECT
                        Order_No,
                        Product_ID,
                        OrderType_Desc,
                        ActivationOrder,
                        Account_ID,
                        Account_Name,
                        AccountType_Desc,
                        Price,
                        Name,
                        SKU,
                        SIM,
                        ESN,
                        COMMISSION_AMOUNT,
                        COMMISSION_TYPE,
                        NON_COMMISSIONED_REASON,
                        SpiffResponseDate,
                        TcetraOrderDate,
                        TcetraFilledDate,
                        TcetraDueDate,
                        Filled,
                        Process,
                        Void,
                        Rnum
                    FROM #allresults
                    WHERE
                        Rnum = 1
                        AND AccountType_Desc != 'Vendor'
                    UNION
                    SELECT
                        f.Order_No,
                        f.Product_ID,
                        f.OrderType_Desc,
                        f.ActivationOrder,
                        f.Account_ID,
                        f.Account_Name,
                        f.AccountType_Desc,
                        f.Price,
                        f.Name,
                        f.SKU,
                        f.SIM,
                        f.ESN,
                        f.COMMISSION_AMOUNT,
                        f.COMMISSION_TYPE,
                        f.NON_COMMISSIONED_REASON,
                        f.SpiffResponseDate,
                        f.TcetraOrderDate,
                        f.TcetraFilledDate,
                        f.TcetraDueDate,
                        f.Filled,
                        f.Process,
                        f.Void,
                        f.Rnum
                    FROM #final AS f
                    WHERE AccountType_Desc != 'Vendor'
                ) AS a
            JOIN dbo.Account AS a2
                ON a2.Account_ID = a.Account_ID
            ORDER BY
                Order_No ASC,
                SpiffResponseDate DESC,
                COMMISSION_AMOUNT DESC,
                Rnum DESC,
                TcetraFilledDate ASC,
                TcetraOrderDate ASC;



        END;



END TRY
BEGIN CATCH

    SELECT
        ERROR_NUMBER() AS ErrorNumber,
        ERROR_MESSAGE() AS ErrorMessage;
END CATCH;
END
-- noqa: disable=all;

