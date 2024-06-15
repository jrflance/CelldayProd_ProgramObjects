--liquibase formatted sql

--changeset Sammer Bazerbashi:0a9sdjf;lik3 stripComments:false runOnChange:true endDelimiter:/

-- noqa: disable=all


-- =============================================
--             :
--      Author : Angela Bogantz
--             :
--     Created : 2018-04-17
--             :
-- Description : process tracfone billing for residuals
--             :
--       Usage : EXEC Tracfone.[P_ProcessBilling_Residuals] @FileID = 14989
--             :
--  AB20180517 : Hard coded new commission type "Promo Reimbursement - TW Data Addon" to Account 123018
--  AB20180727 : Adding Type 5 - "PROMO REIMBURSEMENT - SM MONTH 3" to the hard coded to Account 123018 AB27
--  AB20181119 : Updated case statment with PaymentAccountID to replace hard coding
--  SB20211102 : Support for withholding for NSF accounts
--  MR20211208 : Summing the withholding amounts together before paying out to eliminate the violation of PK on Operations.tblResidualPaymentHistory
--			   :	Removing one of the two account 149393 inserts into #withholding
--  SB20231018 : Added filling pending rebate orders driven by the residual file approval to 123018
--  SB20231025 : Handling for Branded Handsets to follow TracFone reimbursement amounts only - based on new v. port
--  SB20240611 : DFY Withholding
-- =============================================
CREATE OR ALTER	PROCEDURE [Tracfone].[P_ProcessBilling_Residuals]
(@FileID INT)
AS
BEGIN TRY

    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;


    IF NOT EXISTS
    (
        SELECT 1
        FROM Tracfone.tblFile f
        WHERE f.FileId = @FileID
              AND f.FileTypeId = 12 --Residual file type
              AND f.FileStatusId = 2 --Imported
    )
    BEGIN;
        THROW 51000, 'Dealer Residual with this file ID has been processed or is not a residual file ID', 1;
        RETURN;
    END;

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


    UPDATE f
    SET f.FileStatusId = 20,
        f.LastUpdateDate = GETDATE() --Residual Processing
    FROM Tracfone.tblFile f
    WHERE f.FileId = @FileID
          AND f.FileTypeId = 12;

    IF OBJECT_ID('tempdb..#ListOrdersToProcess0') IS NOT NULL
    BEGIN
        DROP TABLE #ListOrdersToProcess0;
    END;

    CREATE TABLE #ListOrdersToProcess0
    (
        Price DECIMAL(10, 2),
        TSP_ID VARCHAR(15),
        ResidualTypeID INT,
        AccountType_ID INT,
        SpiffProduct_ID VARCHAR(50)
    );

    INSERT INTO #ListOrdersToProcess0
    SELECT -1 * SUM(CAST(dcd.COMMISSION_AMOUNT AS DECIMAL(7, 2))),
           CASE
               WHEN ISNULL(rt.PaymentAccountID, 0) <> 0 THEN
                   rt.PaymentAccountID --ab201811
               WHEN LEN(dcd.TSP_ID) >= 10 THEN
                   SUBSTRING(dcd.TSP_ID, 1, 5)
               ELSE
                   dcd.TSP_ID
           END [AccountID],
           rt.ResidualTypeID,
           a.AccountType_ID,
           rt.SpiffProduct_ID
    FROM Tracfone.tblDealerCommissionDetail dcd
        JOIN Operations.tblResidualType rt
            ON dcd.COMMISSION_TYPE = rt.ResidualType --AB limits to residuals
        JOIN dbo.Account a
            ON CASE
                   WHEN ISNULL(rt.PaymentAccountID, 0) <> 0 THEN
                       rt.PaymentAccountID --ab201811
                   WHEN LEN(dcd.TSP_ID) >= 10 THEN
                       SUBSTRING(dcd.TSP_ID, 1, 5)
                   ELSE
                       dcd.TSP_ID
               END = a.Account_ID
    WHERE dcd.FileId = @FileID
    GROUP BY CASE
                 WHEN ISNULL(rt.PaymentAccountID, 0) <> 0 THEN
                     rt.PaymentAccountID --ab201811
                 WHEN LEN(dcd.TSP_ID) >= 10 THEN
                     SUBSTRING(dcd.TSP_ID, 1, 5)
                 ELSE
                     dcd.TSP_ID
             END,
             dcd.COMMISSION_TYPE,
             rt.ResidualTypeID,
             rt.SpiffProduct_ID,
             a.AccountType_ID;
    -- SELECT * FROM #ListOrdersToProcess0 ORDER BY TSP_ID, ResidualTypeID

    DELETE tmp
    FROM #ListOrdersToProcess0 tmp
    WHERE EXISTS
    (
        SELECT 1
        FROM Operations.tblResidualPaymentHistory rph
        WHERE rph.Account_ID = tmp.TSP_ID
              AND rph.FileId = @FileID
              AND rph.ResidualTypeID = tmp.ResidualTypeID
    );



    IF OBJECT_ID('tempdb..#ListOrdersToProcess') IS NOT NULL
    BEGIN
        DROP TABLE #ListOrdersToProcess;
    END;

    SELECT SUM(l.Price) AS Price, --MR20211208
           CASE
               WHEN w.accountID IS NOT NULL THEN
                   '150250'
               ELSE
                   l.TSP_ID
           END TSP_ID,
           l.ResidualTypeID,
           l.AccountType_ID,
           l.SpiffProduct_ID
    INTO #ListOrdersToProcess
    FROM #ListOrdersToProcess0 l
        LEFT JOIN #withhold w
            ON l.TSP_ID = w.accountID
    GROUP BY CASE
                 WHEN w.accountID IS NOT NULL THEN
                     '150250'
                 ELSE
                     l.TSP_ID
             END,
             l.ResidualTypeID,
             l.AccountType_ID,
             l.SpiffProduct_ID;

    DECLARE Transaction_cursor CURSOR FOR
    SELECT TSP_ID,
           Price,
           ResidualTypeID,
           SpiffProduct_ID,
           AccountType_ID
    FROM #ListOrdersToProcess;

    DECLARE @Price DECIMAL(10, 2),
            @ResidualTypeID TINYINT,
            @SpiffProduct_ID INT,
            @AccountID INT,
            @DateFrom DATETIME = GETDATE(),
            @SpiffDebitAccountID INT = 58361,
            @paymentOrderType INT,
            @newOrderNo INT,
            @newOrderItem INT,
            @AccountType_ID INT,
            @vendorPrice DECIMAL(10, 2),
            @SpifforderNo INT,
            @spifforderItemID INT;

    OPEN Transaction_cursor;

    FETCH NEXT FROM Transaction_cursor
    INTO @AccountID,
         @Price,
         @ResidualTypeID,
         @SpiffProduct_ID,
         @AccountType_ID;
    WHILE @@FETCH_STATUS = 0
    BEGIN

        IF (@AccountType_ID = 11)
        BEGIN
            SET @paymentOrderType = 38;
        END;
        ELSE
        BEGIN
            SET @paymentOrderType = 28;
        END;

        EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @AccountID,              -- int
                                                              @Datefrom = @DateFrom,                -- datetime
                                                              @OrdertypeID = @paymentOrderType,     -- int
                                                              @OrderRefNumber = NULL,               -- int
                                                              @ProductID = @SpiffProduct_ID,        -- int  --AB
                                                              @Amount = @Price,                     -- decimal
                                                              @DiscountAmount = 0,                  -- decimal
                                                              @NewOrderID = @newOrderItem OUTPUT,   -- int
                                                              @NewOrderNumber = @newOrderNo OUTPUT; -- int

        INSERT INTO Operations.tblResidualPaymentHistory
        (
            Account_ID,
            FileId,
            OrderNo,
            ResidualTypeID
        )
        VALUES
        (   @AccountID,     -- account_id - int
            @FileID,        -- FileId - int
            @newOrderNo,    -- OrderNo - int
            @ResidualTypeID -- ResidualTypeID - tinyint
            );

        UPDATE dbo.Orders
        SET Addons = CAST(DATEPART(MONTH, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(YEAR, GETDATE()) AS VARCHAR(4))
        WHERE ID = @newOrderItem;

        IF (@AccountType_ID = 11)
        BEGIN
            UPDATE dbo.Order_No
            SET Paid = 1
            WHERE Order_No = @newOrderNo;

            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt - ISNULL(@Price, 0),
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt - ISNULL(@Price, 0)
            WHERE Account_ID = @AccountID;
        END;

        --create spiffdebit
        SET @vendorPrice = -1 * @Price;
        EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @SpiffDebitAccountID,      -- int
                                                              @Datefrom = @DateFrom,                  -- datetime
                                                              @OrdertypeID = 25,                      -- int
                                                              @OrderRefNumber = @newOrderNo,          -- int
                                                              @ProductID = 3767,                      -- int
                                                              @Amount = @vendorPrice,                 -- decimal
                                                              @DiscountAmount = 0,                    -- decimal
                                                              @NewOrderID = @spifforderItemID OUTPUT, -- int
                                                              @NewOrderNumber = @SpifforderNo OUTPUT; -- int

        --SELECT @AccountID, @newOrderNo

        FETCH NEXT FROM Transaction_cursor
        INTO @AccountID,
             @Price,
             @ResidualTypeID,
             @SpiffProduct_ID,
             @AccountType_ID;

    END;

    CLOSE Transaction_cursor;

    DEALLOCATE Transaction_cursor;



    --2023-10-18  SB
    --Fill pending rebates driven by TC reimbursements to 123018 on residual file


    DECLARE @FileDate DATETIME;

    SET @FileDate =
    (
        SELECT TOP (1)
               CAST(tdcd.Create_Date AS DATE)
        FROM Tracfone.tblDealerCommissionDetail AS tdcd
        WHERE tdcd.FileId = @FileID
        ORDER BY CAST(tdcd.Create_Date AS DATE)
    );



    IF OBJECT_ID('tempdb..#DCD') IS NOT NULL
    BEGIN
        DROP TABLE #DCD;
    END;


    SELECT dcd.TSP_ID,
           dcd.PIN,
           dcd.RTR_TXN_REFERENCE1,
           dcd.COMMISSION_TYPE,
           CAST(dcd.Create_Date AS DATE) AS [Create_Date],
           dcd.FileId,
           2 PType,
           dcd.DealerCommissionDetailID,
           dcd.NON_COMMISSIONED_REASON,
           dcd.COMMISSION_AMOUNT
    INTO #DCD
    FROM Tracfone.tblDealerCommissionDetail dcd
    WHERE CAST(dcd.Create_Date AS DATE) >= CAST(GETDATE() AS DATE)
          AND dcd.COMMISSION_TYPE IN ( 'Branded Handset', 'handset' )
          AND TRY_CAST(dcd.COMMISSION_AMOUNT AS DECIMAL(6, 2)) > 0
          AND dcd.ConsignmentProcessed = 0;



    CREATE NONCLUSTERED INDEX dcd
    ON #DCD (
                TSP_ID,
                PIN,
                RTR_TXN_REFERENCE1,
                COMMISSION_TYPE
            );

    IF OBJECT_ID('tempdb..#ListOrdersToProcessPromo') IS NOT NULL
    BEGIN
        DROP TABLE #ListOrdersToProcessPromo;
    END;

    CREATE TABLE #ListOrdersToProcessPromo
    (
        Order_No INT,
        [SKU] VARCHAR(50),            --Changed to SKU 20190419
        COMMISSION_TYPE VARCHAR(50),  --added 20190419
        TSP_ID VARCHAR(15),
        ProcessAccountID VARCHAR(15), --JL20191011
        DetailID INT,
        NON_COMMISSION_REASON VARCHAR(30),
        COMMISSION_AMOUNT DECIMAL(10, 2)
    );



    INSERT INTO #ListOrdersToProcessPromo
    (
        Order_No,
        SKU,
        COMMISSION_TYPE,
        TSP_ID,
        DetailID,
        NON_COMMISSION_REASON,
        COMMISSION_AMOUNT
    )
    SELECT DISTINCT
           ttf.Order_No,
           dcd.PIN AS [SKU],
           dcd.COMMISSION_TYPE, --added 20190419
           ttf.TSP_ID,
           dcd.DealerCommissionDetailID,
           dcd.NON_COMMISSIONED_REASON,
           dcd.COMMISSION_AMOUNT
    FROM #DCD dcd
        JOIN Tracfone.tblTSPTransactionFeed ttf
            ON dcd.PIN = ttf.TXN_PIN
               AND ttf.TXN_PIN <> ''
               AND ttf.Date_Created >= DATEADD(DAY, -365, @FileDate)
               AND ttf.Date_Created < DATEADD(DAY, 1, @FileDate)
               AND ttf.TXN_TYPE = 'DEB'
        JOIN Tracfone.tblTracfoneProduct pp WITH (READUNCOMMITTED)
            ON pp.TracfoneProductID = ttf.PRODUCT_SKU
               AND pp.ProcessBilling = 1
    WHERE ttf.TXN_PIN <> ''
          AND dcd.PIN <> ''
          AND ISNUMERIC(dcd.PIN) = 1
          AND ISNUMERIC(dcd.TSP_ID) = 1
    GROUP BY ttf.Order_No,
             dcd.PIN,
             ttf.TSP_ID,
             dcd.COMMISSION_TYPE, --added 20190419
             ttf.AdditionalMonthsProcessed,
             dcd.DealerCommissionDetailID,
             dcd.NON_COMMISSIONED_REASON,
             dcd.COMMISSION_AMOUNT
    UNION
    SELECT DISTINCT
           ttf.Order_No,
           dcd.RTR_TXN_REFERENCE1 AS [SKU],
           dcd.COMMISSION_TYPE, --added 20190419
           ttf.TSP_ID,
           dcd.DealerCommissionDetailID,
           dcd.NON_COMMISSIONED_REASON,
           dcd.COMMISSION_AMOUNT
    FROM #DCD dcd
        JOIN Tracfone.tblTSPTransactionFeed ttf WITH (READUNCOMMITTED)
            ON dcd.RTR_TXN_REFERENCE1 = ttf.RTR_TXN_REFERENCE1
               AND ttf.RTR_TXN_REFERENCE1 <> ''
               AND ttf.Date_Created >= DATEADD(DAY, -365, @FileDate)
               AND ttf.Date_Created < DATEADD(DAY, 1, @FileDate)
               AND ttf.TXN_TYPE = 'DEB'
        JOIN Tracfone.tblTracfoneProduct pp WITH (READUNCOMMITTED)
            ON pp.TracfoneProductID = ttf.PRODUCT_SKU
               AND pp.ProcessBilling = 1
    WHERE dcd.RTR_TXN_REFERENCE1 <> ''
          AND ISNUMERIC(dcd.TSP_ID) = 1
          AND ISNUMERIC(dcd.RTR_TXN_REFERENCE1) = 1
    GROUP BY ttf.Order_No,
             ttf.PRODUCT_SKU, --added 2019-04-22
             dcd.RTR_TXN_REFERENCE1,
             ttf.TSP_ID,
             dcd.COMMISSION_TYPE,
             dcd.DealerCommissionDetailID,
             dcd.NON_COMMISSIONED_REASON,
             dcd.COMMISSION_AMOUNT;



    IF OBJECT_ID('tempdb..#rebateinfo') IS NOT NULL
    BEGIN
        DROP TABLE #rebateinfo;
    END;

    SELECT DISTINCT
           o.Order_No ActivationOrder,
           lp.SKU,
           o2.Order_No RebateOrder,
           o2.OrderTotal RebateAmount,
           lp.DetailID,
           lp.COMMISSION_AMOUNT,
           '1' Type
    INTO #rebateinfo
    FROM #ListOrdersToProcessPromo lp
        JOIN dbo.Order_No o
            ON o.Order_No = lp.Order_No
        JOIN dbo.Orders o1
            ON o.Order_No = o1.Order_No
        JOIN dbo.tblOrderItemAddons toia
            ON toia.OrderID = o1.ID
               AND toia.AddonsValue = lp.SKU
               AND toia.AddonsID = 196
        JOIN dbo.Order_No o2
            ON o2.AuthNumber = o.Order_No
    WHERE o2.Account_ID != 58361
          AND o2.OrderType_ID IN ( 59, 60 )
          AND o2.Filled = 0
          AND o2.Process = 0
          AND o2.Void = 0
    UNION
    SELECT DISTINCT
           o.Order_No ActivationOrder,
           lp.SKU,
           o2.Order_No RebateOrder,
           o2.OrderTotal RebateAmount,
           lp.DetailID,
           lp.COMMISSION_AMOUNT,
           '1' Type
    FROM #ListOrdersToProcessPromo lp
        JOIN dbo.Orders o1
            ON lp.SKU = o1.SKU
        JOIN dbo.Order_No o
            ON o.Order_No = lp.Order_No
        JOIN dbo.Order_No o2
            ON o2.AuthNumber = o.Order_No
    WHERE o2.Account_ID != 58361
          AND o2.OrderType_ID IN ( 59, 60 )
          AND o2.Filled = 0
          AND o2.Process = 0
          AND o2.Void = 0;

    DECLARE @order_No INT,
            @SKU VARCHAR(100),            --changed form PIN to SKU 20190422
            @Commission_Type VARCHAR(50), --Added 20190419
            @TSP_ID INT,                  --was @AccountID
            @AccountTypeID INT,
            @SpiffordertypeID INT,
            @ProcessDate DATETIME = GETDATE(),
            @RebateOrder INT,
            @DetailID INT,
            @Commission_Amount DECIMAL(10, 2),
            @NonCommissionReason VARCHAR(30),
            @ApprovedCommission_Amount DECIMAL(10, 2),
            @Type TINYINT;

    DECLARE addSpiff_cursor CURSOR FAST_FORWARD FOR
    SELECT DISTINCT
           lp.Order_No,
           lp.SKU,
           lp.COMMISSION_TYPE,
           ISNULL(lp.ProcessAccountID, lp.TSP_ID) AS [TSP_ID],
           r.RebateOrder,
           lp.DetailID,
           r.RebateAmount * -1 OrderTotal, --update
           lp.NON_COMMISSION_REASON,
           lp.COMMISSION_AMOUNT,
           r.Type
    FROM #ListOrdersToProcessPromo lp
        JOIN #rebateinfo r
            ON r.ActivationOrder = lp.Order_No;



    OPEN addSpiff_cursor;

    FETCH NEXT FROM addSpiff_cursor
    INTO @order_No,
         @SKU,
         @Commission_Type,
         @TSP_ID,
         @RebateOrder,
         @DetailID,
         @Commission_Amount,
         @NonCommissionReason,
         @ApprovedCommission_Amount,
         @Type;

    WHILE @@FETCH_STATUS = 0
    BEGIN



        SELECT @AccountTypeID = AccountType_ID
        FROM dbo.Account
        WHERE Account_ID = @TSP_ID;



        UPDATE Tracfone.tblDealerCommissionDetail
        SET ConsignmentProcessed = 1
        WHERE DealerCommissionDetailID = @DetailID;


        --2023-02-16 Removal of requirement for the port to be swtiched to new.  All pending rebates will be filled based on the amount provided from TracFone

        IF @Type = 1
        BEGIN

            UPDATE dbo.Orders
            SET Price = @ApprovedCommission_Amount * -1
            WHERE Order_No = @RebateOrder;

            DECLARE @DueDate DATE;
            EXEC OrderManagment.P_OrderManagment_CalculateDueDate @AccountID = @TSP_ID,       -- int
                                                                  @Date = @ProcessDate,       -- datetime
                                                                  @DueDate = @DueDate OUTPUT; -- date

            UPDATE dbo.Order_No
            SET Filled = 1,
                Process = 1,
                Void = 0,
                DateFilled = @ProcessDate,
                DateDue = @DueDate
            WHERE Order_No = @RebateOrder;

        END;



        UPDATE dbo.Account
        SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt + @ApprovedCommission_Amount,
            AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt + @ApprovedCommission_Amount
        WHERE Account_ID = @TSP_ID;




        FETCH NEXT FROM addSpiff_cursor
        INTO @order_No,
             @SKU,
             @Commission_Type,
             @TSP_ID,
             @RebateOrder,
             @DetailID,
             @Commission_Amount,
             @NonCommissionReason,
             @ApprovedCommission_Amount,
             @Type;


    END;


    CLOSE addSpiff_cursor;

    DEALLOCATE addSpiff_cursor;




    UPDATE f
    SET f.FileStatusId = 21,
        f.LastUpdateDate = GETDATE() --Residual Processed
    FROM Tracfone.tblFile f
    WHERE f.FileId = @FileID
          AND f.FileTypeId = 12;

END TRY
BEGIN CATCH
    UPDATE f
    SET f.FileStatusId = 22,
        f.LastUpdateDate = GETDATE() --Residual Process Error
    FROM Tracfone.tblFile f
    WHERE f.FileId = @FileID
          AND f.FileTypeId = 12;

    SELECT ERROR_NUMBER() AS ErrorNumber,
           ERROR_MESSAGE() AS ErrorMessage;

END CATCH;

-- noqa: disable=all;
/
