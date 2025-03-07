--liquibase formatted sql

--changeset Sammer Bazerbashi:0D555C stripComments:false runOnChange:true endDelimiter:/

-- noqa: disable=all
-- =============================================
--             :
--      Author : Angela Bogantz
--             :
--     Created : 2019-05-16
--             :
-- Description : process tracfone month 2 and month 3 billing (and later 4, 5, and 6)
--             : Based of off [Tracfone].[P_ProcessBilling_2nd_Month_Spiff]
--             :
--  JL20191011 : Support for tblOrderItemBilling
--  SB20201117 : Support for month 1, month 2, and month 3 rebates
--  SB20201207 : Support for additional month spiff redirect - rebates currently never get delayed
--  SB20201215 : Support for checking retrospiff for bundled plan is paid and allowing redirect to 123018
--					(additional month SP updated to pay full amount on retrospiff if instant not paid)
--  CH20210101 : Issue on performance on join on order_no.AuthNumber (scan instead of seek). Change with convert.
--  SB20201229 : Support for only Month 2 and Month 3 redirect to 123018.  Month 4 will get paid to dealer BAU.
--  SB20210216 : "PHONE PROMO ADJUSTMENT"
--  SB20211102 : Support for withholding for NSF accounts
--  SB20220816 : Support for BYOP MIGRATION
--  MH20240215 : Removed ParentItemID to accommidate activation fee
--  SB20240215 : Logic added to separate additional month ordertypes from promo order types for activation fee spiffs
--  SB20240416 : Logic added to handle Null value for addons for PType =1
--  SB20240611 : DFY Withholding
-- =============================================
CREATE OR ALTER	PROC Tracfone.P_ProcessBilling_Additional_Month_Spiff
(
    @FileID INT,
    @Days INT = -365
)
AS
BEGIN

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    DECLARE @FileDate DATETIME;

    SET @FileDate =
    (
        SELECT TOP (1)
               CAST(tdcd.Create_Date AS DATE)
        FROM Tracfone.tblDealerCommissionDetail AS tdcd
        WHERE tdcd.FileId = @FileID
        ORDER BY CAST(tdcd.Create_Date AS DATE)
    );

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

    IF OBJECT_ID('tempdb..#DCD') IS NOT NULL
    BEGIN
        DROP TABLE #DCD;
    END;

    SELECT dcd.DealerCommissionDetailID,
           dcd.TSP_ID,
           dcd.PIN,
           dcd.RTR_TXN_REFERENCE1,
           dcd.COMMISSION_TYPE,
           dcd.COMMISSION_AMOUNT,
           CAST(dcd.Create_Date AS DATE) AS [Create_Date],
           dcd.FileId,
           1 AS PType
    INTO #DCD
    FROM Tracfone.tblDealerCommissionDetail AS dcd
    WHERE dcd.FileId = @FileID
          AND dcd.COMMISSION_TYPE IN ( 'MONTH 2 SPIFF', 'MONTH 3 SPIFF', 'MONTH 4 SPIFF', 'MONTH 5 SPIFF',
                                       'MONTH 6 SPIFF'
                                     )
          AND TRY_CAST(dcd.COMMISSION_AMOUNT AS DECIMAL(6, 2)) > 0 --AND dcd.COMMISSION_AMOUNT > '0';
    UNION
    SELECT dcd.DealerCommissionDetailID,
           dcd.TSP_ID,
           dcd.PIN,
           dcd.RTR_TXN_REFERENCE1,
           dcd.COMMISSION_TYPE,
           dcd.COMMISSION_AMOUNT,
           CAST(dcd.Create_Date AS DATE) AS [Create_Date],
           dcd.FileId,
           2 AS PType
    FROM Tracfone.tblDealerCommissionDetail AS dcd
    WHERE dcd.FileId = @FileID
          AND dcd.COMMISSION_TYPE IN ( 'MONTH 1 PHONE PROMO', 'MONTH 2 PHONE PROMO', 'MONTH 3 PHONE PROMO',
                                       'PHONE PROMO ADJUSTMENT', 'BYOP MIGRATION', 'ACTIVATION FEE SPIFF'
                                     )
          AND TRY_CAST(dcd.COMMISSION_AMOUNT AS DECIMAL(6, 2)) > 0
          AND dcd.ConsignmentProcessed = 0;


    CREATE NONCLUSTERED INDEX dcd
    ON #DCD (
                TSP_ID,
                PIN,
                RTR_TXN_REFERENCE1,
                COMMISSION_TYPE
            );

    IF OBJECT_ID('tempdb..#ListOrdersToProcess') IS NOT NULL
    BEGIN
        DROP TABLE #ListOrdersToProcess;
    END;

    CREATE TABLE #ListOrdersToProcess
    (
        Order_No INT,
        PRODUCT_SKU INT,                   --added 2019-04-22
        [SKU] VARCHAR(50),                 --Changed to SKU 20190419
        Commission_Amount VARCHAR(50),
        COMMISSION_TYPE VARCHAR(50),       --added 20190419
        TSP_ID VARCHAR(15),
        AdditionalMonthsProcessed TINYINT, --updated 20190419
        ProcessAccountID VARCHAR(15),      --JL20191011
        PType TINYINT,
        DetailID INT
    );

    INSERT INTO #ListOrdersToProcess
    (
        Order_No,
        PRODUCT_SKU,
        SKU,
        Commission_Amount,
        COMMISSION_TYPE,
        TSP_ID,
        AdditionalMonthsProcessed,
        PType,
        DetailID
    )
    SELECT DISTINCT -- noqa: AM01
           ttf.Order_No,
           ttf.PRODUCT_SKU,     --added 2019-04-22
           dcd.PIN AS [SKU],
           MAX(dcd.COMMISSION_AMOUNT) AS Commission_Amount,
           dcd.COMMISSION_TYPE, --added 20190419
           dcd.TSP_ID,
           ttf.AdditionalMonthsProcessed,
           dcd.PType,
           dcd.DealerCommissionDetailID AS DetailID
    FROM #DCD AS dcd
        JOIN Tracfone.tblTSPTransactionFeed AS ttf
            ON ttf.TSP_ID = dcd.TSP_ID
               AND dcd.PIN = ttf.TXN_PIN
               AND ttf.TXN_PIN <> ''
               AND ttf.Date_Created >= DATEADD(DAY, @Days, @FileDate)
               AND ttf.Date_Created < DATEADD(DAY, 1, @FileDate)
               AND ttf.TXN_TYPE = 'DEB'
        JOIN Tracfone.tblTracfoneProduct AS pp WITH (READUNCOMMITTED)
            ON pp.TracfoneProductID = ttf.PRODUCT_SKU
               AND pp.ProcessBilling = 1
    WHERE ttf.TXN_PIN <> ''
          AND dcd.PIN <> ''
          AND ISNUMERIC(dcd.PIN) = 1
          AND ISNUMERIC(dcd.TSP_ID) = 1
    GROUP BY ttf.Order_No,
             ttf.PRODUCT_SKU,     --added 2019-04-22
             dcd.PIN,
             dcd.TSP_ID,
             dcd.COMMISSION_TYPE, --added 20190419
             ttf.AdditionalMonthsProcessed,
             dcd.PType,
             dcd.DealerCommissionDetailID
    UNION
    SELECT DISTINCT -- noqa: AM01
           ttf.Order_No,
           ttf.PRODUCT_SKU,     --added 2019-04-22
           dcd.RTR_TXN_REFERENCE1 AS [SKU],
           MAX(dcd.COMMISSION_AMOUNT) AS Commission_Amount,
           dcd.COMMISSION_TYPE, --added 20190419
           dcd.TSP_ID,
           ttf.AdditionalMonthsProcessed,
           dcd.PType,
           dcd.DealerCommissionDetailID AS DetailID
    FROM #DCD AS dcd
        JOIN Tracfone.tblTSPTransactionFeed AS ttf WITH (READUNCOMMITTED)
            ON ttf.TSP_ID = dcd.TSP_ID
               AND dcd.RTR_TXN_REFERENCE1 = ttf.RTR_TXN_REFERENCE1
               AND ttf.RTR_TXN_REFERENCE1 <> ''
               AND ttf.Date_Created >= DATEADD(DAY, @Days, @FileDate)
               AND ttf.Date_Created < DATEADD(DAY, 1, @FileDate)
               AND ttf.TXN_TYPE = 'DEB'
        JOIN Tracfone.tblTracfoneProduct AS pp WITH (READUNCOMMITTED)
            ON pp.TracfoneProductID = ttf.PRODUCT_SKU
               AND pp.ProcessBilling = 1
    WHERE dcd.RTR_TXN_REFERENCE1 <> ''
          AND ISNUMERIC(dcd.TSP_ID) = 1
          AND ISNUMERIC(dcd.RTR_TXN_REFERENCE1) = 1
    GROUP BY ttf.Order_No,
             ttf.PRODUCT_SKU,     --added 2019-04-22
             dcd.RTR_TXN_REFERENCE1,
             dcd.TSP_ID,
             dcd.COMMISSION_TYPE, --added 20190419
             ttf.AdditionalMonthsProcessed,
             dcd.PType,
             dcd.DealerCommissionDetailID;
    --remove marked processed
    DELETE lp
    FROM #ListOrdersToProcess AS lp
    WHERE lp.PType IN ( 1 )
          AND NOT EXISTS
    (
        SELECT 1
        FROM #ListOrdersToProcess AS l
        WHERE (
                  (
                      l.COMMISSION_TYPE = 'MONTH 2 SPIFF'
                      AND l.AdditionalMonthsProcessed & 2 = 0
                  )
                  OR
                  (
                      l.COMMISSION_TYPE = 'MONTH 3 SPIFF'
                      AND l.AdditionalMonthsProcessed & 4 = 0
                  )
                  OR
                  (
                      l.COMMISSION_TYPE = 'MONTH 4 SPIFF'
                      AND l.AdditionalMonthsProcessed & 8 = 0
                  )
                  OR
                  (
                      l.COMMISSION_TYPE = 'MONTH 5 SPIFF'
                      AND l.AdditionalMonthsProcessed & 16 = 0
                  )
                  OR
                  (
                      l.COMMISSION_TYPE = 'MONTH 6 SPIFF'
                      AND l.AdditionalMonthsProcessed & 32 = 0
                  )
              )
              AND l.COMMISSION_TYPE = lp.COMMISSION_TYPE
              AND l.SKU = lp.SKU
              AND l.Order_No = lp.Order_No
              AND l.TSP_ID = lp.TSP_ID
    );

    --remove refill orders
    DELETE l
    FROM #ListOrdersToProcess AS l
    WHERE EXISTS
    (
        SELECT 1
        FROM dbo.Order_No AS o
        WHERE o.Order_No = l.Order_No
              AND o.OrderType_ID IN ( 43, 44 ) --Refills and Promos
    );


    --Set ProcessAccountID
    UPDATE lp
    SET lp.ProcessAccountID = oib.IncentiveOwner
    FROM #ListOrdersToProcess AS lp
        JOIN dbo.Orders AS o
            ON o.Order_No = lp.Order_No
               AND o.SKU = lp.SKU
        JOIN OrderManagment.tblOrderItemBilling AS oib
            ON o.ID = oib.OrdersId
               AND ISNULL(oib.IncentiveOwner, 0) <> 0;

    -- This removes the spiff that was already paid from the list of orders to process to prevent paying twice on the same record from Tracfone
    DELETE lp
    FROM #ListOrdersToProcess AS lp
        JOIN Products.tblProductCarrierMapping AS pcm
            ON pcm.ProductId = lp.PRODUCT_SKU
        JOIN Tracfone.tblCarrierCommissionProductMapping AS ccpm
            ON ccpm.CommissionType = lp.COMMISSION_TYPE
               AND ccpm.Carrier_id = pcm.CarrierId
    WHERE EXISTS
    (
        SELECT 1
        FROM dbo.Orders AS o
            JOIN dbo.Order_No AS n
                ON o.Order_No = n.Order_No
                   AND
                   (
                       (CAST(n.Account_ID AS VARCHAR(15)) = ISNULL(lp.ProcessAccountID, lp.TSP_ID))
                       OR (EXISTS
    (
        SELECT 1
        FROM Operations.tblResidualType AS trt
        WHERE trt.C_StoreOverrideAccount = n.Account_ID
    )
                          )
                   )
                   AND n.Filled = 1
                   AND n.Process = 1
                   AND n.Void = 0
                   AND
                   (
                       (
                           n.OrderType_ID IN ( 30, 34 )
                           AND lp.PType = 1
                       )
                       OR
                       (
                           n.OrderType_ID IN ( 59, 60 )
                           AND lp.PType = 2
                       )
                   )
        WHERE o.Product_ID = ccpm.Product_id
              AND o.SKU = lp.SKU
              AND o.Price < 0
    );

    --same sku purchased twice by same account, also returned
    IF OBJECT_ID('tempdb..#Duplicates') IS NOT NULL
    BEGIN
        DROP TABLE #Duplicates;
    END;

    SELECT l.TSP_ID,
           l.SKU,
           l.COMMISSION_TYPE
    INTO #Duplicates
    FROM #ListOrdersToProcess AS l
    GROUP BY l.TSP_ID,
             l.SKU,
             l.COMMISSION_TYPE
    HAVING COUNT(l.Order_No) > 1;

    IF OBJECT_ID('tempdb..#FirstLastDup') IS NOT NULL
    BEGIN
        DROP TABLE #FirstLastDup;
    END;

    SELECT l.TSP_ID,
           l.SKU,
           l.COMMISSION_TYPE,
           l.PRODUCT_SKU,
           MIN(l.Order_No) AS [FirstOrder],
           MAX(l2.Order_No) AS [LastOrder]
    INTO #FirstLastDup
    FROM #Duplicates AS d
        JOIN #ListOrdersToProcess AS l
            ON l.COMMISSION_TYPE = d.COMMISSION_TYPE
               AND l.SKU = d.SKU
               AND l.TSP_ID = d.TSP_ID
        JOIN #ListOrdersToProcess AS l2
            ON l2.COMMISSION_TYPE = d.COMMISSION_TYPE
               AND l2.SKU = d.SKU
               AND l2.TSP_ID = d.TSP_ID
               AND l2.PRODUCT_SKU = l.PRODUCT_SKU
    GROUP BY l.TSP_ID,
             l.SKU,
             l.COMMISSION_TYPE,
             l.PRODUCT_SKU;

    --remove returned orders
    DELETE l
    FROM #ListOrdersToProcess AS l
    WHERE EXISTS
    (
        SELECT d.FirstOrder
        FROM #FirstLastDup AS d
            JOIN dbo.Order_No AS n
                ON n.AuthNumber = CAST(d.FirstOrder AS VARCHAR(50))
                   AND n.OrderType_ID IN ( 1, 9 ) --to start finding returns
                   AND n.Filled = 1
                   AND n.Process = 1
                   AND n.Void = 0
            JOIN dbo.Orders AS o
                ON o.Order_No = n.Order_No
                   AND o.Product_ID = d.PRODUCT_SKU --return with same product
                   AND o.Price < 0
                   AND d.FirstOrder = l.Order_No
    );


    IF OBJECT_ID('tempdb..#rebateinfo') IS NOT NULL
    BEGIN
        DROP TABLE #rebateinfo;
    END;
    --find ESN data for promos
    SELECT DISTINCT
           lp.DetailID,
           o3.Dropship_Qty,
           toia.AddonsValue,
           af.AddonID
    INTO #rebateinfo
    FROM #ListOrdersToProcess AS lp
        JOIN Order_No AS o
            ON o.Order_No = lp.Order_No
        JOIN dbo.Orders AS o1
            ON o.Order_No = o1.Order_No
               AND o1.ParentItemID = 0
        --JOIN dbo.Products AS p					--MH20240215
        --  ON o1.Product_ID = p.Product_ID AND p.Product_Type = 3
        LEFT JOIN dbo.tblOrderItemAddons AS toia
            ON toia.OrderID = o1.ID
        JOIN dbo.tblAddonFamily AS af
            ON toia.AddonsID = af.AddonID
               AND af.AddonTypeName IN ( 'DeviceBYOPType', 'DeviceType' )
        LEFT JOIN dbo.Order_No AS o2
            ON o2.AuthNumber = o.Order_No
               AND o2.OrderType_ID IN ( 59, 60 )
               AND o2.Filled = 1
               AND o2.Process = 1
               AND o2.Void = 0
        JOIN dbo.Orders AS o3
            ON o3.Order_No = o2.Order_No
    WHERE lp.PType = 2;


    ------------------------------------------

    IF OBJECT_ID('tempdb..#Processed') IS NOT NULL
    BEGIN
        DROP TABLE #Processed;
    END;

    CREATE TABLE #Processed
    (
        Order_No INT NOT NULL --added not null 20190423
    );

    DECLARE @order_No INT,
            @SKU VARCHAR(100),                --changed form PIN to SKU 20190422
            @Commission_Amount DECIMAL(5, 2), -- was tracSpiff
            @Commission_Type VARCHAR(50),     --Added 20190419
            @TSP_ID INT,                      --was @AccountID
            @OriginalProduct_ID INT,          --was @ProductID
            @CarrierID INT,
            @SpiffProductID INT,              --was @addSpiffProductID
            @AccountTypeID INT,
            @SpiffordertypeID INT,
            @SpiffAmount DECIMAL(5, 2),
            @ProcessDate DATETIME = GETDATE(),
            @SpiffDebitAccountID INT = 58361,
            @SpifforderNo INT,
            @spifforderItemID INT,
            @PType TINYINT,
            @DetailID INT,
            @PromoID INT,
            @ESN NVARCHAR(30),
            @AddonID INT;

    DECLARE addSpiff_cursor CURSOR FAST_FORWARD FOR
    --added DISTINCT for dups in tf
    SELECT DISTINCT
           lp.Order_No,
           lp.SKU,
           lp.Commission_Amount,
           lp.COMMISSION_TYPE,
           CASE
               WHEN lp.PType = 1
                    AND lp.COMMISSION_TYPE IN ( 'MONTH 2 SPIFF', 'MONTH 3 SPIFF' )
                    AND EXISTS
                        (
                            SELECT 1
                            FROM Products.tblXRefilProductMapping AS x
                            WHERE x.OrigProductID = lp.PRODUCT_SKU
                                  AND x.StatusID = 1
                                  AND x.IndIsActive = 1
                        )
                    AND ISNULL(
                        (
                            SELECT ISNULL(SUM(a.Price), 0) AS Price
                            FROM
                            (
                                SELECT DISTINCT
                                       SUM(ISNULL(o1.Price, 0)) AS Price
                                FROM Orders AS o1
                                    JOIN Order_No AS o2
                                        ON o2.Order_No = o1.Order_No
                                    JOIN dbo.Products AS p --MH20240215
                                        ON o1.Product_ID = p.Product_ID
                                           AND p.Product_Type = 4
                                WHERE o1.Order_No = lp.Order_No
                                      --AND o1.ParentItemID != 0				--MH20240215 (removed)
                                      AND o2.OrderType_ID IN ( 22, 23 )
                                UNION
                                SELECT DISTINCT
                                       SUM(ISNULL(o1.Price, 0)) AS Price
                                FROM Orders AS o1
                                    JOIN Order_No AS o2
                                        ON o2.Order_No = o1.Order_No
                                WHERE o2.AuthNumber = CONVERT(NVARCHAR(50), lp.Order_No) --CH20210101 -- noqa: CV11
                                      AND o2.OrderType_ID IN ( 45, 46 )
                                      AND o2.Filled = 1
                                      AND o2.Process = 1
                                      AND o2.Void = 0
                            ) AS a
                        ),
                        0
                              ) < 0 THEN
                   '123018'
               WHEN w.accountID IS NOT NULL THEN
                   '150250'
               WHEN EXISTS
                    (
                        SELECT 1
                        FROM Operations.tblOrdersToNotPaySpiff AS np
                        WHERE lp.Order_No = np.Order_no
                    ) THEN
                   '124315'
               ELSE
                   ISNULL(lp.ProcessAccountID, lp.TSP_ID)
           END AS [TSP_ID],
           lp.PRODUCT_SKU AS [OriginalProduct_ID],
           cpm.CarrierId,
           ccpm.Product_id AS [SpiffProductID],
           lp.PType,
           lp.DetailID,
           r.Dropship_Qty,
           r.AddonsValue,
           r.AddonID
    FROM #ListOrdersToProcess AS lp
        JOIN Products.tblProductCarrierMapping AS cpm WITH (READUNCOMMITTED)
            ON cpm.ProductId = lp.PRODUCT_SKU
        JOIN Tracfone.tblCarrierCommissionProductMapping AS ccpm
            ON cpm.CarrierId = ccpm.Carrier_id
               AND ccpm.CommissionType = lp.COMMISSION_TYPE
        LEFT JOIN #rebateinfo AS r
            ON r.DetailID = lp.DetailID
        LEFT JOIN #withhold AS w
            ON w.accountID = lp.TSP_ID;


    OPEN addSpiff_cursor;

    FETCH NEXT FROM addSpiff_cursor
    INTO @order_No,
         @SKU,
         @Commission_Amount,
         @Commission_Type,
         @TSP_ID,
         @OriginalProduct_ID,
         @CarrierID,
         @SpiffProductID,
         @PType,
         @DetailID,
         @PromoID,
         @ESN,
         @AddonID;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SELECT @AccountTypeID = AccountType_ID
        FROM dbo.Account
        WHERE Account_ID = @TSP_ID;

        IF (@PType = 1)
        BEGIN
            IF (@AccountTypeID = 2)
                SET @SpiffordertypeID = 34;
            ELSE
                SET @SpiffordertypeID = 30;




            IF (@Commission_Type = 'MONTH 2 SPIFF')
            BEGIN
                UPDATE Tracfone.tblTSPTransactionFeed
                SET AdditionalMonthsProcessed = AdditionalMonthsProcessed | 2
                WHERE @order_No = Order_No
                      AND
                      (
                          (
                              @SKU = TXN_PIN
                              AND TXN_PIN <> ''
                          )
                          OR
                          (
                              @SKU = RTR_TXN_REFERENCE1
                              AND RTR_TXN_REFERENCE1 <> ''
                          )
                      );
            END;

            IF (@Commission_Type = 'MONTH 3 SPIFF')
            BEGIN
                UPDATE Tracfone.tblTSPTransactionFeed
                SET AdditionalMonthsProcessed = AdditionalMonthsProcessed | 4
                WHERE @order_No = Order_No
                      AND
                      (
                          (
                              @SKU = TXN_PIN
                              AND TXN_PIN <> ''
                          )
                          OR
                          (
                              @SKU = RTR_TXN_REFERENCE1
                              AND RTR_TXN_REFERENCE1 <> ''
                          )
                      );
            END;

            IF @Commission_Type = 'MONTH 4 SPIFF'
            BEGIN
                UPDATE Tracfone.tblTSPTransactionFeed --add for month 4 spiff
                SET AdditionalMonthsProcessed = AdditionalMonthsProcessed | 8
                WHERE @order_No = Order_No
                      AND
                      (
                          (
                              @SKU = TXN_PIN
                              AND TXN_PIN <> ''
                          )
                          OR
                          (
                              @SKU = RTR_TXN_REFERENCE1
                              AND RTR_TXN_REFERENCE1 <> ''
                          )
                      );
            END;

            IF @Commission_Type = 'MONTH 5 SPIFF'
            BEGIN
                UPDATE Tracfone.tblTSPTransactionFeed --add for month 5 spiff
                SET AdditionalMonthsProcessed = AdditionalMonthsProcessed | 16
                WHERE @order_No = Order_No
                      AND
                      (
                          (
                              @SKU = TXN_PIN
                              AND TXN_PIN <> ''
                          )
                          OR
                          (
                              @SKU = RTR_TXN_REFERENCE1
                              AND RTR_TXN_REFERENCE1 <> ''
                          )
                      );
            END;

            IF @Commission_Type = 'MONTH 6 SPIFF'
            BEGIN
                UPDATE Tracfone.tblTSPTransactionFeed --add for month 6 spiff
                SET AdditionalMonthsProcessed = AdditionalMonthsProcessed | 32
                WHERE @order_No = Order_No
                      AND
                      (
                          (
                              @SKU = TXN_PIN
                              AND TXN_PIN <> ''
                          )
                          OR
                          (
                              @SKU = RTR_TXN_REFERENCE1
                              AND RTR_TXN_REFERENCE1 <> ''
                          )
                      );
            END;








            SET @SpiffAmount = -1 * @Commission_Amount;
            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @TSP_ID,
                                                                  @Datefrom = @ProcessDate,
                                                                  @OrdertypeID = @SpiffordertypeID,
                                                                  @OrderRefNumber = @order_No,
                                                                  @ProductID = @SpiffProductID,
                                                                  @Amount = @SpiffAmount,
                                                                  @DiscountAmount = 0,
                                                                  @NewOrderID = @spifforderItemID OUTPUT,
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT;

            INSERT INTO #Processed
            (
                Order_No
            )
            VALUES
            (@SpifforderNo);

            UPDATE dbo.Orders
            SET SKU = @SKU
            WHERE ID = @spifforderItemID;

            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @Commission_Amount,
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @Commission_Amount
            WHERE Account_ID = @TSP_ID;

            UPDATE dbo.Order_No
            SET DateDue = CAST(DATEADD(DAY, 1, GETDATE()) AS DATE),
                Paid = 1
            WHERE Order_No = @SpifforderNo
                  AND OrderType_ID = 30;

            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @SpiffDebitAccountID,
                                                                  @Datefrom = @FileDate,
                                                                  @OrdertypeID = 25,
                                                                  @OrderRefNumber = @order_No,
                                                                  @ProductID = 3767,
                                                                  @Amount = @Commission_Amount,
                                                                  @DiscountAmount = 0,
                                                                  @NewOrderID = @spifforderItemID OUTPUT,
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT;
        END;


        IF @PType = 2
        BEGIN

            IF (@AccountTypeID = 2 AND @SpiffProductID != 21865)
                SET @SpiffordertypeID = 59;
            ELSE IF (@AccountTypeID = 11 AND @SpiffProductID != 21865)
                SET @SpiffordertypeID = 60;


            IF (@AccountTypeID = 2 AND @SpiffProductID = 21865) --Activation Fee Spiff
                SET @SpiffordertypeID = 34;
            ELSE IF (@AccountTypeID = 11 AND @SpiffProductID = 21865)
                SET @SpiffordertypeID = 30;



            UPDATE Tracfone.tblDealerCommissionDetail
            SET ConsignmentProcessed = 1
            WHERE DealerCommissionDetailID = @DetailID;


            SET @SpiffAmount = -1 * @Commission_Amount;
            EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @TSP_ID,
                                                                  @Datefrom = @ProcessDate,
                                                                  @OrdertypeID = @SpiffordertypeID,
                                                                  @OrderRefNumber = @order_No,
                                                                  @ProductID = @SpiffProductID,
                                                                  @Amount = @SpiffAmount,
                                                                  @DiscountAmount = 0,
                                                                  @NewOrderID = @spifforderItemID OUTPUT,
                                                                  @NewOrderNumber = @SpifforderNo OUTPUT;



            INSERT INTO #Processed
            (
                Order_No
            )
            VALUES
            (@SpifforderNo);

            UPDATE dbo.Orders
            SET Dropship_Qty = @PromoID,
                SKU = @SKU
            WHERE ID = @spifforderItemID;



            IF ISNULL(@ESN, '') <> ''
            BEGIN
                INSERT INTO dbo.tblOrderItemAddons
                (
                    OrderID,
                    AddonsID,
                    AddonsValue
                )
                VALUES
                (@spifforderItemID, @AddonID, @ESN);

            END;



            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @Commission_Amount,
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @Commission_Amount
            WHERE Account_ID = @TSP_ID;


        END;


        FETCH NEXT FROM addSpiff_cursor
        INTO @order_No,
             @SKU,
             @Commission_Amount,
             @Commission_Type,
             @TSP_ID,
             @OriginalProduct_ID,
             @CarrierID,
             @SpiffProductID,
             @PType,
             @DetailID,
             @PromoID,
             @ESN,
             @AddonID;
    END;

    CLOSE addSpiff_cursor;

    DEALLOCATE addSpiff_cursor;

    SELECT n.Order_No,
           n.Account_ID,
           o.Name,
           o.Price,
           n.DateOrdered,
           n.OrderType_ID,
           o.SKU,
           n.AuthNumber,
           o.Dropship_Qty,
           toia.AddonsValue
    FROM #Processed AS r
        JOIN dbo.Orders AS o WITH (READUNCOMMITTED)
            ON o.Order_No = r.Order_No
        JOIN dbo.Order_No AS n WITH (READUNCOMMITTED)
            ON n.Order_No = o.Order_No
        LEFT JOIN dbo.tblOrderItemAddons AS toia
            ON toia.OrderID = o.ID;

END;
-- noqa: disable=all;
/
