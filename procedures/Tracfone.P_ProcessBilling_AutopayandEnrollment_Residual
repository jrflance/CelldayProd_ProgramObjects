--liquibase formatted sql

--changeset Sammer Bazerbashi:90324jklwef stripComments:false runOnChange:true endDelimiter:/
-- noqa: disable=all
-- noqa: disable=all
-- =============================================
--    Author   :  Samer Bazerbashi
--        Date : 2017-03-31
-- Description : Process Tracfone autopay airtime margins and enrollments
-- LZ20170510  : Change for autopay spiff payment automation
-- AB20171109  : Update second update @AccountType_ID to @accountType_ID2
-- AB20171117  : Update DateDue to CAST(DateDue as DATE) AB1
-- SB20240325  : Insert bill item number into addons
-- example : EXEC Tracfone.[P_ProcessBilling_AutopayandEnrollment_Residual] @FileID = 302

-- =============================================
-- noqa: enable=all
-- noqa: disable=all
CREATE OR Alter PROC Tracfone.P_ProcessBilling_AutopayandEnrollment_Residual
(@FileID INT)
AS
BEGIN

    CREATE TABLE #ListOrdersToProcess
    (
        price DECIMAL(6, 2),
        TSP_ID VARCHAR(15),
        AccountType_ID INT,
        COMMISSION_TYPE VARCHAR(100),
        Sim VARCHAR(50),
        DealerCommissionDetailID INT,
        RTR_TXN_REFERENCE1 INT
    );

    INSERT INTO #ListOrdersToProcess
    SELECT -1 * CAST(dcd.COMMISSION_AMOUNT AS DECIMAL(6, 2)),
           CASE
               WHEN LEN(dcd.TSP_ID) >= 10 THEN
                   SUBSTRING(dcd.TSP_ID, 1, 5)
               ELSE
                   dcd.TSP_ID
           END [AccountID],
           a.AccountType_ID,
           dcd.COMMISSION_TYPE,
           dcd.SIM,
           dcd.DealerCommissionDetailID,
           dcd.RTR_TXN_REFERENCE1
    FROM Tracfone.tblDealerCommissionDetail dcd WITH (READUNCOMMITTED)
        JOIN dbo.Account a
            ON CASE
                   WHEN LEN(dcd.TSP_ID) >= 10 THEN
                       SUBSTRING(dcd.TSP_ID, 1, 5)
                   ELSE
                       dcd.TSP_ID
               END = a.Account_ID
    WHERE COMMISSION_TYPE IN ( 'AUTOPAY RESIDUAL', 'AUTOPAY ENROLLMENT' )
          AND NOT EXISTS
    (
        SELECT 1
        FROM OrderManagment.tblProviderReference
        WHERE ReferenceID = CAST(dcd.DealerCommissionDetailID AS VARCHAR)
              AND Source = 'Trac Autopay Residual'
    )
          AND dcd.FileId = @FileID
          AND dcd.NEABARResidualProcessed != 1;


    DECLARE Transaction_cursor CURSOR FOR
    SELECT TSP_ID,
           price,
           AccountType_ID,
           Sim,
           DealerCommissionDetailID,
           RTR_TXN_REFERENCE1
    FROM #ListOrdersToProcess
    WHERE COMMISSION_TYPE = 'AUTOPAY RESIDUAL';


    DECLARE @ESN VARCHAR(50),
            @OrderNo INT,
            @Price DECIMAL(5, 2),
            @Processed BIT,
            @AccountID INT,
            @OrdertypeID INT,
            @DealerCommissionDetailID INT,
            @DateFrom DATETIME = GETDATE(),
            @SpiffDebitAccountID INT = 58361,
            @paymentOrderType INT,
            @Product_ID INT,
            @newOrderNo INT,
            @newOrderItem INT,
            @AccountType_ID INT,
            @vednorPrice DECIMAL(6, 2),
            @SpifforderNo INT,
            @spifforderItemID INT,
            @Sim VARCHAR(50),
            @Rtrtxnreference INT;


    OPEN Transaction_cursor;

    FETCH NEXT FROM Transaction_cursor
    INTO @AccountID,
         @Price,
         @AccountType_ID,
         @Sim,
         @DealerCommissionDetailID,
         @Rtrtxnreference;
    WHILE @@FETCH_STATUS = 0
    BEGIN

        UPDATE Tracfone.tblDealerCommissionDetail
        SET NEABARResidualProcessed = 1
        WHERE DealerCommissionDetailID = @DealerCommissionDetailID;

        IF (@AccountType_ID = 11)
            SET @paymentOrderType = 38;
        ELSE IF (@AccountType_ID = 2)
            SET @paymentOrderType = 28;


        EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @AccountID,              -- int
                                                              @Datefrom = @DateFrom,                -- datetime
                                                              @OrdertypeID = @paymentOrderType,     -- int
                                                              @OrderRefNumber = NULL,               -- int
                                                              @ProductID = 8115,                    -- int
                                                              @Amount = @Price,                     -- decimal
                                                              @DiscountAmount = 0,                  -- decimal
                                                              @NewOrderID = @newOrderItem OUTPUT,   -- int
                                                              @NewOrderNumber = @newOrderNo OUTPUT; -- int

        INSERT INTO OrderManagment.tblProviderReference
        (
            OrderNo,
            ReferenceID,
            AccountID,
            Source
        )
        VALUES
        (   @newOrderNo,               -- OrderNo - int
            @DealerCommissionDetailID, -- ReferenceID - nvarchar(25)
            @AccountID,                -- AccountID - int
            'Trac Autopay Residual'    -- Source - varchar(100)
            );

        UPDATE dbo.Orders
        SET Addons = CAST(DATEPART(MONTH, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(YEAR, GETDATE()) AS VARCHAR(4))
        WHERE ID = @newOrderItem;


        IF ISNULL(@Sim, '') != ''
        BEGIN
            INSERT INTO dbo.tblOrderItemAddons
            (
                OrderID,
                AddonsID,
                AddonsValue
            )
            VALUES
            (   @newOrderItem, -- OrderID - int
                171,           -- AddonsID - int
                @Sim           -- AddonsValue - nvarchar(200)
                );
        END;

        IF ISNULL(@Rtrtxnreference, '') != ''
        BEGIN
            INSERT INTO dbo.tblOrderItemAddons
            (
                OrderID,
                AddonsID,
                AddonsValue
            )
            VALUES
            (   @newOrderItem,   -- OrderID - int
                196,             -- AddonsID - int
                @Rtrtxnreference -- AddonsValue - nvarchar(200)
                );
        END;

        IF (@AccountType_ID = 11)
        BEGIN
            UPDATE dbo.Order_No
            SET Paid = 1,
                DateDue = CAST(DateDue AS DATE) --AB1
            WHERE Order_No = @newOrderNo;

            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt - @Price,
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt - @Price
            WHERE Account_ID = @AccountID;
        END;

        --create spiffdebit
        SET @vednorPrice = -1 * @Price;
        EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @SpiffDebitAccountID,      -- int
                                                              @Datefrom = @DateFrom,                  -- datetime
                                                              @OrdertypeID = 25,                      -- int
                                                              @OrderRefNumber = @newOrderNo,          -- int
                                                              @ProductID = 3767,                      -- int
                                                              @Amount = @vednorPrice,                 -- decimal
                                                              @DiscountAmount = 0,                    -- decimal
                                                              @NewOrderID = @spifforderItemID OUTPUT, -- int
                                                              @NewOrderNumber = @SpifforderNo OUTPUT; -- int


        --SELECT @AccountID, @newOrderNo

        FETCH NEXT FROM Transaction_cursor
        INTO @AccountID,
             @Price,
             @AccountType_ID,
             @Sim,
             @DealerCommissionDetailID,
             @Rtrtxnreference;
    END;

    CLOSE Transaction_cursor;

    DEALLOCATE Transaction_cursor;






    DECLARE Transaction_cursor2 CURSOR FOR
    SELECT TSP_ID,
           price,
           AccountType_ID,
           Sim,
           DealerCommissionDetailID
    FROM #ListOrdersToProcess
    WHERE COMMISSION_TYPE = 'AUTOPAY ENROLLMENT';


    DECLARE @Price2 DECIMAL(5, 2),
            @AccountID2 INT,
            @DealerCommissionDetailID2 INT,
            @DateFrom2 DATETIME = GETDATE(),
            @SpiffDebitAccountID2 INT = 58361,
            @paymentOrderType2 INT,
            @newOrderNo2 INT,
            @newOrderItem2 INT,
            @AccountType_ID2 INT,
            @vednorPrice2 DECIMAL(6, 2),
            @SpifforderNo2 INT,
            @spifforderItemID2 INT,
            @Sim2 VARCHAR(50),
            @Rtrtxnreference2 INT;;


    OPEN Transaction_cursor2;

    FETCH NEXT FROM Transaction_cursor2
    INTO @AccountID2,
         @Price2,
         @AccountType_ID2,
         @Sim2,
         @DealerCommissionDetailID2;
    WHILE @@FETCH_STATUS = 0
    BEGIN

        UPDATE Tracfone.tblDealerCommissionDetail
        SET NEABARResidualProcessed = 1
        WHERE DealerCommissionDetailID = @DealerCommissionDetailID2;

        IF (@AccountType_ID2 = 11)
            SET @paymentOrderType2 = 38;
        ELSE IF (@AccountType_ID2 = 2)
            SET @paymentOrderType2 = 28;


        EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @AccountID2,              -- int
                                                              @Datefrom = @DateFrom2,                -- datetime
                                                              @OrdertypeID = @paymentOrderType2,     -- int
                                                              @OrderRefNumber = NULL,                -- int
                                                              @ProductID = 8113,                     -- int
                                                              @Amount = @Price2,                     -- decimal
                                                              @DiscountAmount = 0,                   -- decimal
                                                              @NewOrderID = @newOrderItem2 OUTPUT,   -- int
                                                              @NewOrderNumber = @newOrderNo2 OUTPUT; -- int

        INSERT INTO OrderManagment.tblProviderReference
        (
            OrderNo,
            ReferenceID,
            AccountID,
            Source
        )
        VALUES
        (   @newOrderNo2,                   -- OrderNo - int
            @DealerCommissionDetailID2,     -- ReferenceID - nvarchar(25)
            @AccountID2,                    -- AccountID - int
            'Trac Autopay Enrollment Bonus' -- Source - varchar(100)
            );

        UPDATE dbo.Orders
        SET Addons = CAST(DATEPART(MONTH, GETDATE()) AS VARCHAR(2)) + CAST(DATEPART(YEAR, GETDATE()) AS VARCHAR(4))
        WHERE ID = @newOrderItem2;



        IF ISNULL(@Sim2, '') != ''
        BEGIN
            INSERT INTO dbo.tblOrderItemAddons
            (
                OrderID,
                AddonsID,
                AddonsValue
            )
            VALUES
            (   @newOrderItem2, -- OrderID - int
                171,            -- AddonsID - int
                @Sim2           -- AddonsValue - nvarchar(200)
                );
        END;


        IF ISNULL(@Rtrtxnreference2, '') != ''
        BEGIN
            INSERT INTO dbo.tblOrderItemAddons
            (
                OrderID,
                AddonsID,
                AddonsValue
            )
            VALUES
            (   @newOrderItem2,   -- OrderID - int
                196,              -- AddonsID - int
                @Rtrtxnreference2 -- AddonsValue - nvarchar(200)
                );
        END;


        IF (@AccountType_ID2 = 11)
        BEGIN
            UPDATE dbo.Order_No
            SET Paid = 1,
                DateDue = CAST(DateDue AS DATE) --AB1
            WHERE Order_No = @newOrderNo2;

            UPDATE dbo.Account
            SET AvailableTotalCreditLimit_Amt = AvailableTotalCreditLimit_Amt - @Price2,
                AvailableDailyCreditLimit_Amt = AvailableDailyCreditLimit_Amt - @Price2
            WHERE Account_ID = @AccountID2;
        END;

        --create spiffdebit
        SET @vednorPrice = -1 * @Price2;
        EXEC OrderManagment.P_OrderManagment_Build_Full_Order @AccountID = @SpiffDebitAccountID2,      -- int
                                                              @Datefrom = @DateFrom2,                  -- datetime
                                                              @OrdertypeID = 25,                       -- int
                                                              @OrderRefNumber = @newOrderNo2,          -- int
                                                              @ProductID = 3767,                       -- int
                                                              @Amount = @vednorPrice2,                 -- decimal
                                                              @DiscountAmount = 0,                     -- decimal
                                                              @NewOrderID = @spifforderItemID2 OUTPUT, -- int
                                                              @NewOrderNumber = @SpifforderNo2 OUTPUT; -- int


        --SELECT @AccountID, @newOrderNo

        FETCH NEXT FROM Transaction_cursor2
        INTO @AccountID2,
             @Price2,
             @AccountType_ID2,
             @Sim2,
             @DealerCommissionDetailID2,
             @Rtrtxnreference2;;;
    END;

    CLOSE Transaction_cursor2;

    DEALLOCATE Transaction_cursor2;

    DROP TABLE #ListOrdersToProcess;

END;

-- noqa: disable=all;
/
