--liquibase formatted sql

--changeset Sammer Bazerbashi:0D555A stripComments:false runOnChange:true endDelimiter:/

-- noqa: disable=all
-- =============================================
--             :
--      Author : zaher al sabbagh
--             :
--     Created : 2015-07-10
--             :
-- Description : process trafone billing
--             :
--  JL20191011 : Support for tblOrderItemBilling
--  SB20160901 : Added RTR processing
--  SB20160929 : Updated RTR processing to not need order_po_detail transaction id for processing
--  SB20161003 : Added @days variable to allow default of -180 but have manual user to be able to change range
--  SB20161107 : Added limitation to remove returns and prevent duplicate spiff payment
--  AB20171020 : Added Airtime RTRs
--  SB20180116 : Added updates to handle new Simple API
--  AB20180724 : Update Account to 124315 for spiff payment for C Store if in table "Operations.tblOrdersToNotPaySpiff" --AB24
--  JL20191011 : Support for tblOrderItemBilling
--  SB20200205 : Updated to manage margin based products; 20200206 Change the case statement to handle based on incentive owner value exists
--	SB20201215 : Support for paying full amount on Bundled Plans that didn't receive instant spiff: ports, PIP accounts, shadow product or discount class setup issue
--  SB20201229 : Calculation of tier is now driven from Tracfone.tblTierdiscLog to capture discount at the time of activation rather than current disc class
--  SB20210302 : Handle orders built using activatenow.io.  Filled retrospiff >$0 created on the fly with no instant spiff; needs logic below to check for paid flag before making changes to order
--  SB20211103 : Support for withholding from accounts that are NSF
--  sb20220921 : Support for Migration Compensation
--  sb20230321 : Updated Cstore, 138380, retrospiff with $0 amount to get paid properly
--  SB20230518 : Updated bundled plan logic to look for TracFone tier IDs from registration rather than legacy silver, gold, platinum from orders
--  SB20230907 : Added support for ESimNumberType
--  SB20240105 : Updated to allow rerunning without creating duplicates due to feeding it twice.  Also added support for remaining unpaid amounts to be paid using a retroactive spiff order.
--  SB20240226 : Activation fee item handling
--  SB20240611 : DFY Withholding
--             :
-- =============================================
-- noqa: disable=all
CREATE OR ALTER PROCEDURE [Tracfone].[P_ProcessBilling_Delay_Tier]
(
    @FileDate DATETIME,
    @FileID INT,
    @Days INT = -180
)
AS
BEGIN

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    IF OBJECT_ID('tempdb..#withhold') IS NOT NULL
    BEGIN
        DROP TABLE #withhold;
    END;
    CREATE TABLE #withhold
    (
        accountID INT
    );

    --INSERT INTO #withhold
    --VALUES
    --(156404);
    --INSERT INTO #withhold
    --VALUES
    --(156405);
    --INSERT INTO #withhold
    --VALUES
    --(156599);
    --INSERT INTO #withhold
    --VALUES
    --(157128);
    --INSERT INTO #withhold
    --VALUES
    --(157762);
    --INSERT INTO #withhold
    --VALUES
    --(158053);
    --INSERT INTO #withhold
    --VALUES
    --(158171);
    --INSERT INTO #withhold
    --VALUES
    --(158326);
    --INSERT INTO #withhold
    --VALUES
    --(158554);
    --INSERT INTO #withhold
    --VALUES
    --(159130);
    --INSERT INTO #withhold
    --VALUES
    --(160038);
    --INSERT INTO #withhold
    --VALUES
    --(161575);
    --INSERT INTO #withhold
    --VALUES
    --(156597);
    --INSERT INTO #withhold
    --VALUES
    --(156598);
    --INSERT INTO #withhold
    --VALUES
    --(156689);
    --INSERT INTO #withhold
    --VALUES
    --(156960);
    --INSERT INTO #withhold
    --VALUES
    --(157824);
    --INSERT INTO #withhold
    --VALUES
    --(158159);
    --INSERT INTO #withhold
    --VALUES
    --(158161);
    --INSERT INTO #withhold
    --VALUES
    --(158328);
    --INSERT INTO #withhold
    --VALUES
    --(158743);
    --INSERT INTO #withhold
    --VALUES
    --(158879);
    --INSERT INTO #withhold
    --VALUES
    --(159051);
    --INSERT INTO #withhold
    --VALUES
    --(159999);
    --INSERT INTO #withhold
    --VALUES
    --(158881);
    --INSERT INTO #withhold
    --VALUES
    --(158880);
    --INSERT INTO #withhold
    --VALUES
    --(159515);

    IF OBJECT_ID('tempdb..#ListOrdersToProcess') IS NOT NULL
    BEGIN
        DROP TABLE #ListOrdersToProcess;
    END;

    CREATE TABLE #ListOrdersToProcess
    (
        Order_No INT,
        SKUValue VARCHAR(50),
        PinvRTR VARCHAR(50),
        Commission_Amount VARCHAR(50),
        TSP_ID VARCHAR(15),
        Processed BIT,
        ProcessAccountID VARCHAR(15)
    );

    --PINs
    INSERT INTO #ListOrdersToProcess
    (
        Order_No,
        SKUValue,
        PinvRTR,
        Commission_Amount,
        TSP_ID,
        Processed
    )
    SELECT ttf.Order_No,
           dcd.PIN AS [SKUValue], --AB 2017-09-20
           0 AS PinvRTR,
           MAX(dcd.COMMISSION_AMOUNT) AS Commission_Amount,
           dcd.TSP_ID,
           ttf.Processed
    FROM Tracfone.tblDealerCommissionDetail AS dcd WITH (READUNCOMMITTED)
        JOIN Tracfone.tblTSPTransactionFeed AS ttf WITH (READUNCOMMITTED)
            ON ttf.TSP_ID = dcd.TSP_ID
               AND dcd.PIN = ttf.TXN_PIN
        JOIN Tracfone.tblTracfoneProduct AS pp WITH (READUNCOMMITTED)
            ON pp.TracfoneProductID = ttf.PRODUCT_SKU
               AND pp.ProcessBilling = 1
    WHERE dcd.FileId = @FileID
          AND ISNULL(ttf.TSP_ID, '') <> ''
          AND ISNULL(dcd.TSP_ID, '') <> ''
          AND ISNULL(ttf.TXN_PIN, '') <> ''
          AND ISNULL(dcd.PIN, '') <> ''
          AND ttf.Date_Created >= DATEADD(DAY, @Days, @FileDate)
          AND ttf.Date_Created < DATEADD(DAY, 1, @FileDate)
          AND ttf.Processed = 0
          AND dcd.COMMISSION_TYPE IN ( 'ACTIVATION SPIFF', 'MIGRATION COMPENSATION' ) --SB 092122
          AND ttf.TXN_TYPE = 'DEB'
          AND dcd.COMMISSION_AMOUNT <> '0'
          AND NOT EXISTS
    (
        SELECT 1
        FROM Tracfone.tblTSPTransactionFeed AS ttf2
        WHERE ttf2.Order_No = ttf.Order_No
              AND ttf2.Processed = 1
    ) --SB20240105 remove chance of rerunning a day and having another fed record not marked as processed
    GROUP BY ttf.Order_No,
             dcd.PIN,
             dcd.TSP_ID,
             ttf.Processed
    -- optimization CH 20160915: no RTR_TXN_REFERENCE1 vaue can be 'pin' so union all has to be used and read uncommitted hint on all tables
    -- add the filtered index [IX_Tracfone_tblTSPTransactionFeedPinFiltered]
    UNION ALL
    --RTRs
    SELECT DISTINCT -- noqa
           ttf.Order_No,
           dcd.RTR_TXN_REFERENCE1 AS [SKUValue], --AB 2017-09-20
           1 AS PinvRTR,
           MAX(dcd.COMMISSION_AMOUNT) AS Commission_Amount,
           dcd.TSP_ID,
           ttf.Processed
    FROM Tracfone.tblDealerCommissionDetail AS dcd WITH (READUNCOMMITTED)
        JOIN Tracfone.tblTSPTransactionFeed AS ttf WITH (READUNCOMMITTED)
            ON ttf.TSP_ID = dcd.TSP_ID
               AND dcd.RTR_TXN_REFERENCE1 = ttf.RTR_TXN_REFERENCE1
        JOIN Tracfone.tblTracfoneProduct AS pp WITH (READUNCOMMITTED)
            ON pp.TracfoneProductID = ttf.PRODUCT_SKU
               AND pp.ProcessBilling = 1
    WHERE dcd.FileId = @FileID
          AND ISNULL(ttf.TSP_ID, '') <> ''
          AND ISNULL(dcd.TSP_ID, '') <> ''
          AND ISNULL(ttf.RTR_TXN_REFERENCE1, '') <> ''
          AND ISNULL(dcd.RTR_TXN_REFERENCE1, '') <> ''
          AND ttf.Date_Created >= DATEADD(DAY, @Days, @FileDate)
          AND ttf.Date_Created < DATEADD(DAY, 1, @FileDate)
          AND ttf.Processed = 0
          AND dcd.COMMISSION_TYPE IN ( 'ACTIVATION SPIFF', 'MIGRATION COMPENSATION' ) --SB 092122
          AND ttf.TXN_TYPE = 'DEB'
          AND dcd.COMMISSION_AMOUNT <> '0'
          AND NOT EXISTS
    (
        SELECT 1
        FROM Tracfone.tblTSPTransactionFeed AS ttf2
        WHERE ttf2.Order_No = ttf.Order_No
              AND ttf2.Processed = 1
    ) --SB20240105 remove chance of rerunning a day and having another fed record not marked as processed
    GROUP BY ttf.Order_No,
             dcd.RTR_TXN_REFERENCE1,
             dcd.TSP_ID,
             ttf.Processed;

    IF OBJECT_ID('tempdb..#ListWoAddOn0') IS NOT NULL
    BEGIN
        DROP TABLE #ListWoAddOn0;
    END;


    --Activations (Both PIN and RTR)
    SELECT o3.ID,
           op.SKUValue,
           op.Order_No,
           CAST(op.Commission_Amount AS DECIMAL(5, 2)) AS [TracfoneSpiff],
           -1 * o1.Price AS [PaidSpiff],
           0.00 AS [RemainingSpiff],
           ISNULL(o2.Order_No, 0) AS [RetroSpiffOrder],
           ISNULL(o2.OrderTotal, 0) AS [RetroSpiff],
           CASE
               WHEN LEN(op.TSP_ID) >= 10 THEN
                   SUBSTRING(op.TSP_ID, 1, 5)
               ELSE
                   op.TSP_ID
           END AS [AccountID],
           o1.Product_ID,
           o.OrderType_ID,
           op.Processed,
           o.Void,
           op.PinvRTR,
           op.ProcessAccountID
    INTO #ListWoAddOn0
    FROM #ListOrdersToProcess AS op
        JOIN dbo.Order_No AS o WITH (READUNCOMMITTED)
            ON o.Order_No = op.Order_No -- original order
               AND o.OrderType_ID IN ( 22, 23 )
        JOIN dbo.Orders AS o1 WITH (READUNCOMMITTED)
            ON o1.Order_No = o.Order_No --finds instant spiff of $0  --HERE
               AND ISNULL(o1.ParentItemID, 0) <> 0
               AND o1.Price = 0
        JOIN Products AS p
            ON p.Product_ID = o1.Product_ID
        JOIN Products.tblProductType AS pt
            ON pt.ProductTypeID = p.Product_Type
               AND pt.ProductTypeID = 4 --SB20240226  spiff item
        JOIN dbo.Orders AS o3 WITH (READUNCOMMITTED)
            ON o3.Order_No = o.Order_No
               AND ISNULL(o3.ParentItemID, 0) = 0
        LEFT JOIN dbo.Order_No AS o2 WITH (READUNCOMMITTED)
            ON o2.AuthNumber = CONVERT(NVARCHAR(50), o.Order_No) --finds spiff order if there is one pending -- noqa
               AND o2.OrderType_ID IN ( 45, 46 )
               AND o2.Void = 0
               AND o2.Filled = 0
               AND o2.Process = 0
    UNION
    --Check for underpaid amounts on the instant spiff to pay the remainder
    SELECT o3.ID,
           op.SKUValue,
           op.Order_No,
           0.00 AS [TracfoneSpiff],
           0.00 AS [PaidSpiff],
           CAST(op.Commission_Amount AS DECIMAL(5, 2)) - (-1 * o1.Price) AS RemainingSpiff,
           ISNULL(o2.Order_No, 0) AS [RetroSpiffOrder],
           ISNULL(o2.OrderTotal, 0) AS [RetroSpiff],
           CASE
               WHEN LEN(op.TSP_ID) >= 10 THEN
                   SUBSTRING(op.TSP_ID, 1, 5)
               ELSE
                   op.TSP_ID
           END AS [AccountID],
           o1.Product_ID,
           o.OrderType_ID,
           op.Processed,
           o.Void,
           op.PinvRTR,
           op.ProcessAccountID
    FROM #ListOrdersToProcess AS op
        JOIN dbo.Order_No AS o WITH (READUNCOMMITTED)
            ON o.Order_No = op.Order_No -- original order
               AND o.OrderType_ID IN ( 22, 23 )
        JOIN dbo.Orders AS o1 WITH (READUNCOMMITTED)
            ON o1.Order_No = o.Order_No --finds instant spiff of $0  --HERE
               AND ISNULL(o1.ParentItemID, 0) <> 0
               AND o1.Price != 0
        JOIN Products AS p
            ON p.Product_ID = o1.Product_ID
        JOIN Products.tblProductType AS pt
            ON pt.ProductTypeID = p.Product_Type
               AND pt.ProductTypeID = 4 --SB20240226  spiff item
        JOIN dbo.Orders AS o3 WITH (READUNCOMMITTED)
            ON o3.Order_No = o.Order_No
               AND ISNULL(o3.ParentItemID, 0) = 0
        LEFT JOIN dbo.Order_No AS o2 WITH (READUNCOMMITTED)
            ON o2.AuthNumber = CONVERT(NVARCHAR(50), o.Order_No) --finds spiff order if there is one pending -- noqa
               AND o2.OrderType_ID IN ( 45, 46 )
               AND o2.Void = 0
               AND o2.Filled = 0
               AND o2.Process = 0
    WHERE CAST(op.Commission_Amount AS DECIMAL(5, 2)) != -1 * o1.Price
          AND CAST(op.Commission_Amount AS DECIMAL(5, 2)) - (-1 * o1.Price) > 0 --'TracFone Spiff' doesn't equal 'Paid Spiff'
          AND NOT EXISTS
    (
        SELECT 1
        FROM OrderManagment.tblTags AS tt
        WHERE tt.SubjectId = op.Order_No
              AND tt.Tag = 'Remaining Retro Paid'
    );


    --select * from #listwoaddon0

    --Add C-Store and Rural case

    IF OBJECT_ID('tempdb..#ListWoAddOn') IS NOT NULL
    BEGIN
        DROP TABLE #ListWoAddOn;
    END;

    SELECT op.ID,
           op.SKUValue,
           op.Order_No,
           op.TracfoneSpiff,
           op.PaidSpiff,
           op.RemainingSpiff,
           CASE
               WHEN oib.IncentiveOwner != 0 THEN
                   o2.Order_No --if there's an incentive owner, the spiff gets paid to them
               ELSE
                   op.RetroSpiffOrder
           END AS RetroSpiffOrder,
           CASE
               WHEN oib.IncentiveOwner != 0 THEN
                   o3.Price --if there's an incentive owner, the spiff gets paid to them
               ELSE
                   op.RetroSpiff
           END AS RetroSpiff,
           CASE
               WHEN oib.IncentiveOwner != 0 THEN
                   o2.Account_ID --if there's an incentive owner, the spiff gets paid to them
               ELSE
                   op.AccountID
           END AS AccountID,
           op.Product_ID,
           op.OrderType_ID,
           CASE
               WHEN oib.IncentiveOwner != 0 THEN
                   o2.Process
               ELSE
                   op.Processed
           END AS Processed,
           CASE
               WHEN oib.IncentiveOwner != 0 THEN
                   o2.Void
               ELSE
                   op.Void
           END AS Void,
           op.PinvRTR,
           op.ProcessAccountID,
           CASE
               WHEN oib.IncentiveOwner != 0 THEN
                   1
               ELSE
                   0
           END AS MarginBasedProduct
    INTO #ListWoAddOn
    FROM #ListWoAddOn0 AS op
        JOIN dbo.Order_No AS o WITH (READUNCOMMITTED)
            ON o.Order_No = op.Order_No -- original order
               AND o.OrderType_ID IN ( 22, 23 )
        JOIN dbo.Orders AS o1 WITH (READUNCOMMITTED)
            ON o1.Order_No = o.Order_No --finds instant spiff of $0  --HERE
               AND ISNULL(o1.ParentItemID, 0) = 0
        JOIN dbo.Orders AS o3 WITH (READUNCOMMITTED)
            ON o3.Order_No = o.Order_No
               AND ISNULL(o3.ParentItemID, 0) = 0
        LEFT JOIN dbo.Order_No AS o2 WITH (READUNCOMMITTED)
            ON o2.AuthNumber = CONVERT(NVARCHAR(50), o.Order_No) --finds spiff order if there is one pending -- noqa
               AND o2.OrderType_ID IN ( 45, 46 )
               AND o2.Void != 1
        LEFT JOIN OrderManagment.tblOrderItemBilling AS oib
            ON oib.OrdersId = o1.ID
               AND oib.Billable = 0;



    IF OBJECT_ID('tempdb..#ProcessOrderTemp') IS NOT NULL
    BEGIN
        DROP TABLE #ProcessOrderTemp;
    END;

    CREATE TABLE #ProcessOrderTemp
    (
        SKUValue VARCHAR(100),
        sim VARCHAR(50),
        orderNo INT,
        tracSpiff DECIMAL(5, 2),
        PaidSpiff DECIMAL(5, 2),
        RemainingSpiff DECIMAL(5, 2),
        retroSpiffOrder INT,
        [RetroSpiff] DECIMAL(5, 2),
        AccountID VARCHAR(15),
        ProductID INT,
        orderTypeID INT,
        processed BIT,
        void BIT,
        PinvRTR VARCHAR(50),
        ProcessAccountID VARCHAR(15),
        MarginBasedProduct BIT,
        BundledProductID VARCHAR(15),
        TierName VARCHAR(30),
        TierDisc DECIMAL(5, 2),
        Datefilled DATETIME
    );


    INSERT INTO #ProcessOrderTemp
    (
        SKUValue,
        sim,
        orderNo,
        tracSpiff,
        PaidSpiff,
        RemainingSpiff,
        retroSpiffOrder,
        RetroSpiff,
        AccountID,
        ProductID,
        orderTypeID,
        processed,
        void,
        PinvRTR,
        ProcessAccountID,
        MarginBasedProduct
    )
    --Activaions
    SELECT o3.SKUValue,
           oia.AddonsValue AS [SIM],
           o3.Order_No,
           o3.TracfoneSpiff,
           o3.PaidSpiff,
           o3.RemainingSpiff,
           o3.RetroSpiffOrder,
           o3.RetroSpiff,
           o3.AccountID,
           o3.Product_ID,
           o3.OrderType_ID,
           o3.Processed,
           o3.Void,
           o3.PinvRTR,
           o3.ProcessAccountID,
           o3.MarginBasedProduct
    FROM #ListWoAddOn AS o3
        JOIN dbo.tblOrderItemAddons AS oia WITH (READUNCOMMITTED, INDEX(IX_tblOrderItemAddons_OrderId))
            ON oia.OrderID = o3.ID
               AND EXISTS
                   (
                       SELECT 1
                       FROM dbo.tblAddonFamily AS f WITH (READUNCOMMITTED)
                       WHERE f.AddonTypeName IN ( 'simtype', 'SimBYOPType', 'ESimNumberType' )
                             AND f.AddonID = oia.AddonsID
                   )
    UNION ALL
    --Airtime (added RTRs)
    SELECT op2.SKUValue,
           '' AS [SIM],
           ttf.Order_No,
           op2.Commission_Amount,
           0 AS PaidSpiff,
           0 AS RemainingSpiff,
           0 AS RetroSpiffOrder,
           0 AS RetroSpiff,
           CASE
               WHEN LEN(op2.TSP_ID) >= 10 THEN
                   SUBSTRING(op2.TSP_ID, 1, 5)
               ELSE
                   op2.TSP_ID
           END AS [AccountID],
           ttf.PRODUCT_SKU AS [Product_ID],
           o.OrderType_ID,
           op2.Processed,
           o.Void,
           op2.PinvRTR,
           op2.ProcessAccountID,
           0 AS MarginBasedProduct
    FROM #ListOrdersToProcess AS op2
        JOIN Tracfone.tblTSPTransactionFeed AS ttf
            ON ttf.Order_No = op2.Order_No
               AND
               (
                   (
                       ttf.TXN_PIN = op2.SKUValue
                       AND ttf.TXN_GROUP = 'PIN'
                       AND ISNUMERIC(ttf.TXN_PIN) = 1
                   )
                   OR
                   (
                       ttf.RTR_TXN_REFERENCE1 = op2.SKUValue --add RTR AB 2017-09-20
                       AND ttf.TXN_GROUP IN ( 'RTR', 'RML' )
                       AND ISNUMERIC(ttf.RTR_TXN_REFERENCE1) = 1
                   )
               )
        JOIN dbo.Order_No AS o
            ON o.Order_No = ttf.Order_No
               AND o.OrderType_ID NOT IN ( 22, 23 );

    INSERT INTO #ProcessOrderTemp
    (
        SKUValue,
        sim,
        orderNo,
        tracSpiff,
        PaidSpiff,
        RemainingSpiff,
        retroSpiffOrder,
        RetroSpiff,
        AccountID,
        ProductID,
        orderTypeID,
        processed,
        void,
        PinvRTR,
        ProcessAccountID,
        MarginBasedProduct
    )
    --seperate from f.AddonTypeName IN ( 'simtype', 'SimBYOPType' ) to prevent same pin once with ESN and once with SIM
    SELECT op.SKUValue,
           oia.AddonsValue AS [SIM],
           op.Order_No,
           op.TracfoneSpiff,
           op.PaidSpiff,
           op.RemainingSpiff,
           op.RetroSpiffOrder,
           op.RetroSpiff,
           op.AccountID,
           op.Product_ID,
           op.OrderType_ID,
           op.Processed,
           op.Void,
           op.PinvRTR,
           op.ProcessAccountID,
           op.MarginBasedProduct
    FROM #ListWoAddOn AS op
        JOIN dbo.tblOrderItemAddons AS oia WITH (READUNCOMMITTED)
            ON oia.OrderID = op.ID
        JOIN dbo.tblAddonFamily AS f WITH (READUNCOMMITTED)
            ON f.AddonID = oia.AddonsID
               AND f.AddonTypeName IN ( 'DeviceBYOPType', 'DeviceType' )
    WHERE NOT EXISTS
    (
        SELECT 1 FROM #ProcessOrderTemp AS pot WHERE pot.orderNo = op.Order_No
    );

    -- SELECT * FROM #ProcessOrderTemp

    --Mark bundled plans
    UPDATE #ProcessOrderTemp
    SET BundledProductID = x.OrigProductID,
        TierName = ttr.TracfoneTierId, --SB20230518
        Datefilled = o.DateFilled
    FROM #ProcessOrderTemp AS p
        JOIN Order_No AS o
            ON o.Order_No = p.orderNo
        JOIN dbo.Orders AS o1
            ON o1.Order_No = o.Order_No
               AND o1.ParentItemID = 0
        JOIN Products.tblXRefilProductMapping AS x
            ON x.OrigProductID = o1.Product_ID
               AND x.StatusID = 1
               AND x.IndIsActive = 1
        JOIN Tracfone.tblTracTSPAccountRegistration AS ttr
            ON CAST(ttr.Account_ID AS VARCHAR(30)) = CAST(p.AccountID AS VARCHAR(30)); --SB20230518

    --Find Tier discount
    WITH cte
    AS (SELECT p.SKUValue,
               p.orderNo,
               p.AccountID,
               tdl.DiscAmount,
               ROW_NUMBER() OVER (PARTITION BY p.Datefilled ORDER BY tdl.Logdate DESC) AS RNum
        FROM #ProcessOrderTemp AS p
            JOIN Tracfone.tblTierdiscLog AS tdl
                ON tdl.Logdate < p.Datefilled
                   AND tdl.TierName = p.TierName
        WHERE ISNULL(p.BundledProductID, 0) != 0)

    --Assign Tier discount
    UPDATE #ProcessOrderTemp
    SET TierDisc = c.DiscAmount
    FROM cte AS c
        JOIN #ProcessOrderTemp AS p
            ON p.AccountID = c.AccountID
               AND p.orderNo = c.orderNo
               AND p.SKUValue = c.SKUValue
    WHERE c.RNum = 1;


    --Update Bundled Plan Spiff Amount for any tier
    UPDATE #ProcessOrderTemp
    SET tracSpiff = ISNULL(ROUND(((p.TierDisc / 1000) * p2.Retail_Price), 2), 0)
    FROM #ProcessOrderTemp AS p
        JOIN dbo.Products AS p2
            ON p2.Product_ID = p.BundledProductID
    WHERE ISNULL(p.BundledProductID, 0) != 0
          AND p.tracSpiff > 0
          AND p.AccountID != 138380;
    --AND TierName NOT IN ( 'silver', 'bronze' );  --SB20230518

    -- noqa: disable=all
    DECLARE Transaction_cursor CURSOR FOR
    SELECT DISTINCT
           SKUValue,
           sim,
           orderNo,
           tracSpiff,
           PaidSpiff,
           pot.RemainingSpiff,
           retroSpiffOrder,
           RetroSpiff,
           CASE
               WHEN w.accountID IS NOT NULL THEN
                   '150250'
               WHEN EXISTS
                    (
                        SELECT 1
                        FROM Operations.tblOrdersToNotPaySpiff AS np
                        WHERE pot.orderNo = np.Order_no
                    ) THEN
                   '124315'
               ELSE
                   ISNULL(pot.ProcessAccountID, pot.AccountID)
           END AS [AccountID],
           ProductID,
           orderTypeID,
           void,
           PinvRTR,
           MarginBasedProduct,
           o1.Price AS CstoreRetroAmt
    FROM #ProcessOrderTemp AS pot
        LEFT JOIN #withhold AS w
            ON w.accountID = pot.AccountID
        LEFT JOIN Orders AS o1
            ON o1.Order_No = pot.retroSpiffOrder
               AND o1.ParentItemID = 0;
    -- noqa: disable=all



    DECLARE @PINorRTR VARCHAR(100),
            @orderNo INT,
            @tracSpiff DECIMAL(5, 2),
            @PaidSpiff DECIMAL(5, 2),
            @RetroSpiff DECIMAL(5, 2),
            @RetroSpiffOrder INT,
            @AccountID INT,
            @AccountTypeID INT,
            @ProductID INT,
            @orderTypeID INT,
            @VoidedOrderStatus BIT,
            @SIM VARCHAR(50),
            @SpiffDebitAccount INT,
            @spiffDebitOrder INT,
            @ProcessDate DATETIME = GETDATE(),
            @DateDue DATETIME,
            @SpiffordertypeID INT,
            @SpifforderNo INT,
            @spifforderItemID INT,
            @SpiffAmount DECIMAL(5, 2),
            @SpiffDebitAccountID INT = 58361,
            @SpiffDebitComAccount INT,
            @spiffDebitComOrder INT,
            @AgentComm DECIMAL(5, 2),
            @PinvRTR VARCHAR(50),
            @MarginBasedProduct BIT,
            @RetroCStoreAmt DECIMAL(5, 2),
            @RemainingSpiff DECIMAL(5, 2);

    OPEN Transaction_cursor;

    FETCH NEXT FROM Transaction_cursor
    INTO @PINorRTR,
         @SIM,
         @orderNo,
         @tracSpiff,         --Tracfone approved commission_amount
         @PaidSpiff,         --Instant Spiff
         @RemainingSpiff,    --Remaining spiff to paid - instant was paid but more was approved
         @RetroSpiffOrder,   --Retrospiff order
         @RetroSpiff,        --Retrospiff amount
         @AccountID,
         @ProductID,
         @orderTypeID,
         @VoidedOrderStatus, --Activation order void status
         @PinvRTR,
         @MarginBasedProduct,
         @RetroCStoreAmt;
    WHILE @@FETCH_STATUS = 0
    BEGIN

        SET @AgentComm = 0;

        SELECT @AccountTypeID = a.AccountType_ID
        FROM dbo.Account AS a
        WHERE a.Account_ID = @AccountID;

        IF (@tracSpiff <> 0 AND @PinvRTR = 0)
        BEGIN
            UPDATE Tracfone.tblTSPTransactionFeed
            SET Processed = 1
            WHERE Order_No = @orderNo
                  AND TXN_PIN = @PINorRTR;
        END;



        IF (@tracSpiff <> 0 AND @PinvRTR = 1)
        BEGIN
            UPDATE Tracfone.tblTSPTransactionFeed
            SET Processed = 1
            WHERE Order_No = @orderNo
                  AND RTR_TXN_REFERENCE1 = @PINorRTR;
        END;

        UPDATE dbo.Orders
        SET SKU = @PINorRTR
        WHERE Order_No = @RetroSpiffOrder;

        IF (@orderTypeID NOT IN ( 22, 23 ))
        BEGIN
            SELECT @ProductID = AirtimeSpiffID
            FROM Tracfone.tblAirtimeSpiffMapping
            WHERE Product_ID = @ProductID;
        END;

        IF @tracSpiff <> 0 --Tracfone approved commission_amount
           AND @RetroSpiff = 0 --Retrospiff amount
           AND @RetroSpiffOrder = 0 --Retrospiff order
           AND @PaidSpiff = 0 --Instant Spiff
           AND @VoidedOrderStatus = 0 --Activation order void status
           AND NOT EXISTS
        (
            SELECT 1
            FROM Order_No o
                JOIN Order_No o1
                    ON o1.AuthNumber = o.Order_No
                       AND o1.OrderType_ID IN ( 45, 46 )
                       AND o.Filled = 1
                       AND o.Process = 1
                       AND o.Void = 0
            WHERE o.Order_No = @orderNo
        )
        BEGIN

            IF (@AccountTypeID = 2)
                SET @SpiffordertypeID = 46;
            ELSE
                SET @SpiffordertypeID = 45;

            SET @SpiffAmount = -1 * @tracSpiff;
            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @AccountID,                -- int
                                                                  @Datefrom = @ProcessDate,               -- datetime
                                                                  @OrdertypeID = @SpiffordertypeID,       -- int
                                                                  @OrderRefNumber = @orderNo,             -- int
                                                                  @ProductID = @ProductID,                -- int
                                                                  @Amount = @SpiffAmount,                 -- decimal
                                                                  @DiscountAmount = 0,                    -- decimal
                                                                  @NewOrderID = @spifforderItemID OUTPUT, -- int
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT; -- int

            UPDATE dbo.Orders
            SET SKU = @PINorRTR
            WHERE Order_No = @SpifforderNo;

            EXEC [OrderManagment].[P_OrderManagment_CreatefullCommissionPerOrder_FIX] @OrderNo = @SpifforderNo;

            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @tracSpiff,
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @tracSpiff
            WHERE Account_ID = @AccountID;

            --create spiffdebit
            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @SpiffDebitAccountID,      -- int
                                                                  @Datefrom = @FileDate,                  -- datetime
                                                                  @OrdertypeID = 25,                      -- int
                                                                  @OrderRefNumber = @orderNo,             -- int
                                                                  @ProductID = 3767,                      -- int
                                                                  @Amount = @tracSpiff,                   -- decimal
                                                                  @DiscountAmount = 0,                    -- decimal
                                                                  @NewOrderID = @spifforderItemID OUTPUT, -- int
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT; -- int

        END;

        IF (
               @tracSpiff <> 0 --Tracfone approved commission_amount
               AND @tracSpiff <> -1 * @RetroSpiff --(Tracfone approved commission_amount) * -1 * (Retrospiff amount)
               AND @RetroSpiffOrder <> 0 --Retrospiff order
               AND @VoidedOrderStatus = 0 --Activation order void status
           )
        BEGIN
            EXEC OrderManagment.P_OrderManagment_CalculateDueDate @AccountID = @AccountID,    -- int
                                                                  @Date = @ProcessDate,       -- datetime
                                                                  @DueDate = @DateDue OUTPUT; -- date

            IF (
               (
                   SELECT ISNULL(Paid, 0)FROM Order_No WHERE Order_No = @RetroSpiffOrder
               ) = 0
               )
            BEGIN
                UPDATE dbo.Order_No
                SET Filled = 1,
                    Process = 1,
                    Void = 0,
                    DateFilled = GETDATE(),
                    DateDue = @DateDue,
                    OrderTotal = -1 * @tracSpiff
                WHERE Order_No = @RetroSpiffOrder
                      AND Paid = 0;

                UPDATE dbo.Orders
                SET Dropship_Cost = @RetroSpiff,
                    Price = -1 * @tracSpiff
                WHERE Order_No = @RetroSpiffOrder;

                UPDATE dbo.Account
                SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @tracSpiff,
                    AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @tracSpiff
                WHERE Account_ID = @AccountID;

                SELECT @SpiffDebitAccount = VendorAccountID
                FROM dbo.Phone_Active_Kit
                WHERE Sim_ID = @SIM;

                SELECT @spiffDebitOrder = Order_No
                FROM dbo.Order_No WITH (READUNCOMMITTED)
                WHERE Account_ID = @SpiffDebitAccount
                      AND OrderType_ID = 25
                      AND AuthNumber = CAST(@orderNo AS NVARCHAR(50));

                UPDATE dbo.Order_No
                SET OrderTotal = @tracSpiff
                WHERE Order_No = @spiffDebitOrder;

                UPDATE dbo.Orders
                SET Price = @tracSpiff
                WHERE Order_No = @spiffDebitOrder;

                SELECT @SpiffDebitComAccount = CommissionVendorAccountId
                FROM dbo.Phone_Active_Kit
                WHERE Sim_ID = @SIM;

                SELECT @spiffDebitComOrder = Order_No
                FROM dbo.Order_No
                WHERE Account_ID = @SpiffDebitComAccount
                      AND OrderType_ID = 25
                      AND AuthNumber = CAST(@orderNo AS NVARCHAR(50));

                SELECT @AgentComm = SUM(Commission_Amt)
                FROM dbo.Order_Commission
                WHERE Order_No = @RetroSpiffOrder
                      AND Account_ID <> 2;

                UPDATE dbo.Order_No
                SET OrderTotal = ISNULL(@AgentComm, 0)
                WHERE Order_No = @spiffDebitComOrder;

                UPDATE dbo.Orders
                SET Price = ISNULL(@AgentComm, 0)
                WHERE Order_No = @spiffDebitComOrder;
            END;
        END;
        IF (
               @tracSpiff = -1 * @RetroSpiff --(Tracfone approved commission_amount) * -1 * (Retrospiff amount)
               AND @VoidedOrderStatus = 0 --Activation order void status
               AND @MarginBasedProduct = 0
           )
        BEGIN
            IF (@RetroSpiffOrder <> 0)
               AND (
                   (
                       SELECT ISNULL(Paid, 0)FROM Order_No WHERE Order_No = @RetroSpiffOrder
                   ) = 0
                   ) --Retrospiff order
            BEGIN

                EXEC OrderManagment.P_OrderManagment_CalculateDueDate @AccountID = @AccountID,    -- int
                                                                      @Date = @ProcessDate,       -- datetime
                                                                      @DueDate = @DateDue OUTPUT; -- date

                UPDATE dbo.Order_No
                SET Filled = 1,
                    Process = 1,
                    Void = 0,
                    DateFilled = GETDATE(),
                    DateDue = @DateDue
                WHERE Order_No = @RetroSpiffOrder;

                UPDATE dbo.Account
                SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @tracSpiff,
                    AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @tracSpiff
                WHERE Account_ID = @AccountID;

                SELECT @SpiffDebitAccount = VendorAccountID
                FROM dbo.Phone_Active_Kit
                WHERE Sim_ID = @SIM;

                SELECT @spiffDebitOrder = Order_No
                FROM dbo.Order_No WITH (READUNCOMMITTED)
                WHERE Account_ID = @SpiffDebitAccount
                      AND OrderType_ID = 25
                      AND AuthNumber = CAST(@orderNo AS NVARCHAR(50));

                UPDATE dbo.Order_No
                SET OrderTotal = @tracSpiff
                WHERE Order_No = @spiffDebitOrder;

                UPDATE dbo.Orders
                SET Price = @tracSpiff
                WHERE Order_No = @spiffDebitOrder;

                SELECT @SpiffDebitComAccount = CommissionVendorAccountId
                FROM dbo.Phone_Active_Kit
                WHERE Sim_ID = @SIM;

                SELECT @spiffDebitComOrder = Order_No
                FROM dbo.Order_No
                WHERE Account_ID = @SpiffDebitComAccount
                      AND OrderType_ID = 25
                      AND AuthNumber = CAST(@orderNo AS NVARCHAR(50));

                SELECT @AgentComm = SUM(Commission_Amt)
                FROM dbo.Order_Commission
                WHERE Order_No = @RetroSpiffOrder
                      AND Account_ID <> 2;

                UPDATE dbo.Order_No
                SET OrderTotal = ISNULL(@AgentComm, 0)
                WHERE Order_No = @spiffDebitComOrder;

                UPDATE dbo.Orders
                SET Price = ISNULL(@AgentComm, 0)
                WHERE Order_No = @spiffDebitComOrder;

            END;
        END;

        IF (
               @tracSpiff = 0 --Tracfone approved commission_amount
               AND @RetroSpiff <> 0 --Retrospiff amount
               AND @VoidedOrderStatus = 0
           ) --Activation order void status
           AND (
               (
                   SELECT ISNULL(Paid, 0)FROM Order_No WHERE Order_No = @RetroSpiffOrder
               ) = 0
               )
        BEGIN
            EXEC OrderManagment.P_OrderManagment_CalculateDueDate @AccountID = @AccountID,    -- int
                                                                  @Date = @ProcessDate,       -- datetime
                                                                  @DueDate = @DateDue OUTPUT; -- date

            UPDATE dbo.Order_No
            SET Filled = 1,
                Process = 1,
                Void = 0,
                OrderTotal = 0,
                DateFilled = GETDATE(),
                DateDue = @DateDue
            WHERE Order_No = @RetroSpiffOrder;

            UPDATE dbo.Orders
            SET Dropship_Cost = @RetroSpiff,
                Price = 0
            WHERE Order_No = @RetroSpiffOrder;

        END;

        --Find all orders with additional remaining amounts to be paid  (tracSpiff is forced to be $0 for this case only)
        IF (
               @tracSpiff = 0 --Tracfone approved commission_amount
               AND @RemainingSpiff != 0
           ) --Activation order void status
        BEGIN

            IF (@AccountTypeID = 2)
                SET @SpiffordertypeID = 46;
            ELSE
                SET @SpiffordertypeID = 45;

            SET @SpiffAmount = -1 * @RemainingSpiff;
            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @AccountID,                -- int
                                                                  @Datefrom = @ProcessDate,               -- datetime
                                                                  @OrdertypeID = @SpiffordertypeID,       -- int
                                                                  @OrderRefNumber = @orderNo,             -- int
                                                                  @ProductID = @ProductID,                -- int
                                                                  @Amount = @SpiffAmount,                 -- decimal
                                                                  @DiscountAmount = 0,                    -- decimal
                                                                  @NewOrderID = @spifforderItemID OUTPUT, -- int
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT; -- int

            UPDATE dbo.Orders
            SET SKU = @PINorRTR
            WHERE Order_No = @SpifforderNo;

            EXEC [OrderManagment].[P_OrderManagment_CreatefullCommissionPerOrder_FIX] @OrderNo = @SpifforderNo;

            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @RemainingSpiff,
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @RemainingSpiff
            WHERE Account_ID = @AccountID;

            --create spiffdebit
            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @SpiffDebitAccountID,      -- int
                                                                  @Datefrom = @FileDate,                  -- datetime
                                                                  @OrdertypeID = 25,                      -- int
                                                                  @OrderRefNumber = @orderNo,             -- int
                                                                  @ProductID = 3767,                      -- int
                                                                  @Amount = @tracSpiff,                   -- decimal
                                                                  @DiscountAmount = 0,                    -- decimal
                                                                  @NewOrderID = @spifforderItemID OUTPUT, -- int
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT; -- int


            INSERT INTO OrderManagment.tblTags
            VALUES
            (   @orderNo,              -- SubjectId - int
                1,                     -- SubjectTypeId - smallint
                'Remaining Retro Paid' -- Tag - varchar(250)
                );

        END;

        FETCH NEXT FROM Transaction_cursor
        INTO @PINorRTR,
             @SIM,
             @orderNo,
             @tracSpiff,
             @PaidSpiff,
             @RemainingSpiff,
             @RetroSpiffOrder,
             @RetroSpiff,
             @AccountID,
             @ProductID,
             @orderTypeID,
             @VoidedOrderStatus,
             @PinvRTR,
             @MarginBasedProduct,
             @RetroCStoreAmt; -- AS20200206 missing element Ticket INC-304682
    END;

    CLOSE Transaction_cursor;
    DEALLOCATE Transaction_cursor;

    DROP TABLE #ListOrdersToProcess;
    DROP TABLE #ProcessOrderTemp;


END;
-- noqa: disable=all;

/
