--liquibase formatted sql

--changeset gaberalawi:48b2df40 stripComments:false runOnChange:true splitStatements:false
-- =============================================
--             : 
--      Author : Melissa Rios
--             : 
--     Created : 2020-09-01
--             : 
-- Description : Used to create refunds to Ultra activation orders through the CRM
--             : 
-- MR20201001  : Added the SKU of the activation as the SKU of the refund order
-- GA20240111  : Assign Return OrderNo as AuthNumber for all return orders, assign commission to return orderItem,
-- remove Ultra check
--			   :
--       Usage : EXEC [OrderManagment].[P_OrderManagment_CreateActivationRefund] 
--          @ActivationOrder = 146876726, @ReturnReason='3'
--			   :
---- =============================================
CREATE OR ALTER PROC [OrderManagment].[P_OrderManagment_CreateActivationRefund]
    (
        @ActivationOrder INT,
        @ReturnReason NTEXT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        SET XACT_ABORT ON;

        DECLARE @ErrorMessage NVARCHAR(4000);
        DECLARE @ErrorSeverity INT;
        DECLARE @ErrorState INT;

        IF OBJECT_ID('tempdb..#ActivationOrderToReturn') IS NOT NULL --clean temp table
            BEGIN
                DROP TABLE #ActivationOrderToReturn;
            END;

        SELECT
            n.Order_No,
            d.ID,
            n.Filled,
            n.Void,
            n.Process,
            n.DateFilled,
            n.Status,
            n.InvoiceNum,
            n.Account_ID,
            n.OrderType_ID,
            d.Product_ID,
            d.Name,
            d.SKU,			--MR20201001
            d.Price,
            d.DiscAmount,
            d.Fee,
            p.Product_Type,
            n.Customer_ID,
            n.ShipTo,
            n.User_ID,
            a.CreditTerms_ID,
            a.DiscountClass_ID,
            n.OrderTotal,
            n.User_IPAddress
        INTO #ActivationOrderToReturn
        FROM dbo.Orders AS d
        JOIN dbo.Order_No AS n
            ON n.Order_No = d.Order_No
        JOIN dbo.Products AS p
            ON p.Product_ID = d.Product_ID
        JOIN dbo.account AS a
            ON a.Account_ID = n.Account_ID
        WHERE n.Order_No = @ActivationOrder;

        --Return an error if it's not an acivation order:
        IF NOT EXISTS (SELECT Order_No FROM #ActivationOrderToReturn WHERE OrderType_ID IN (22, 23))
            BEGIN
                RAISERROR ('This order either does not exist or is not an activation order.', 11, 1);
            END;

        --Return an error if Activation is not filled
        IF EXISTS (SELECT Order_No FROM #ActivationOrderToReturn WHERE Filled != 1)
            BEGIN
                RAISERROR ('This order either does not exist or is not an filled.', 11, 2);
            END;

        --Return an error if it's already been returned or pending return:		
        IF
            EXISTS (
                SELECT 1 FROM dbo.order_No AS n JOIN dbo.OrderType_ID AS o ON o.OrderType_ID = n.OrderType_ID
                WHERE
                    n.AuthNumber = CAST(@ActivationOrder AS VARCHAR(20))
                    AND o.OrderType_Desc IN ('Prepaid Activation Refund', 'Postpaid Activation Refund')
                    AND n.void <> 1
            )
            BEGIN
                RAISERROR ('Order has already been returned or is pending return.', 16, 3);
            END;

        ----------- Finding all spiff/promos/spiff debits etc -----------
        IF OBJECT_ID('tempdb..#OrdersTiedToTheActivation') IS NOT NULL
            BEGIN
                DROP TABLE #OrdersTiedToTheActivation;
            END;

        SELECT
            a.Order_No,
            n.Order_No AS AdditionalOrder_No,
            d.Product_ID,
            d.Name,
            d.Price,
            d.DiscAmount,
            d.Fee,
            n.OrderType_ID,
            n.Filled,
            n.Void,
            n.Process,
            n.Account_ID,
            n.DateFilled,
            n.DateDue,
            n.Status
        INTO #OrdersTiedToTheActivation
        FROM #ActivationOrderToReturn AS a
        JOIN dbo.Order_No AS n
            ON CAST(a.Order_No AS VARCHAR(20)) = n.AuthNumber
        JOIN dbo.Orders AS d
            ON d.Order_No = n.Order_No
        WHERE
            a.Product_Type = 3
            AND n.OrderType_ID NOT IN (22, 23)
            AND d.Price <> 0.00
            AND a.Filled = 1
            AND a.Void = 0
    END TRY
    BEGIN CATCH
        SELECT
            @ErrorMessage = ERROR_MESSAGE(),
            @ErrorSeverity = ERROR_SEVERITY(),
            @ErrorState = ERROR_STATE();

        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState);
        RETURN;
    END CATCH;

    BEGIN TRY
        BEGIN TRANSACTION [Tran1]

        DECLARE @GetDate DATETIME = GETDATE()
        ----------- Generate activation return -----------
        DECLARE
            @Ordertype INT
            = CASE
                WHEN (SELECT n.OrderType_ID FROM #ActivationOrderToReturn AS n WHERE n.Product_Type = 3) = 22
                    THEN
                        (
                            SELECT o.orderType_ID
                            FROM dbo.OrderType_ID AS o
                            WHERE o.OrderType_Desc = 'Postpaid Activation Refund'
                        )
                ELSE
                    (
                        SELECT o.orderType_ID
                        FROM dbo.OrderType_ID AS o
                        WHERE o.OrderType_Desc = 'Prepaid Activation Refund'
                    )
            END,
            @AccountID INT = (SELECT n.Account_ID FROM #ActivationOrderToReturn AS n WHERE n.Product_Type = 3),
            @Product INT = (SELECT d.Product_ID FROM #ActivationOrderToReturn AS d WHERE d.Product_Type = 3),
            @ReturnAmount DECIMAL(9, 2)
            = (SELECT ((d.Price + d.Fee) * -1) FROM #ActivationOrderToReturn AS d WHERE d.Product_Type = 3),
            @DiscountAmount DECIMAL(5, 2)
            = (SELECT ISNULL(d.DiscAmount, 0) * -1 FROM #ActivationOrderToReturn AS d WHERE d.Product_Type = 3)

        DECLARE
            @ReturnOrderID INT,
            @ReturnOrderNumber INT;

        EXEC OrderManagment.P_OrderManagment_Build_Full_Pending_Order
            @AccountID = @AccountID,					-- int
            @Datefrom = @GetDate,                     -- datetime
            @OrdertypeID = @Ordertype,                -- int
            @OrderRefNumber = @ActivationOrder,       -- int
            @ProductID = @Product,                    -- int
            @Amount = @ReturnAmount,                  -- decimal(9, 2)
            @DiscountAmount = @DiscountAmount,        -- decimal(5, 2)
            @NewOrderID = @ReturnOrderID OUTPUT,         -- int
            @NewOrderNumber = @ReturnOrderNumber OUTPUT; -- int

        UPDATE ono
        SET ono.Reason = @ReturnReason
        FROM dbo.Order_No AS ono
        WHERE ono.Order_No = @ReturnOrderNumber

        UPDATE d
        SET d.Fee = (SELECT (a.fee * -1) FROM #ActivationOrderToReturn AS a WHERE a.Product_Type = 3)
        FROM dbo.orders AS d
        WHERE d.id = @ReturnOrderID

        UPDATE n
        SET
            n.ordertotal =
            (
                SELECT ((a.price - a.DiscAmount + a.Fee) + spiff.Price) * -1
                FROM #ActivationOrderToReturn AS a
                JOIN #ActivationOrderToReturn AS spiff
                    ON
                        spiff.Order_No = a.Order_No
                        AND spiff.Product_Type = 4
                WHERE a.Product_Type = 3
            )
        FROM dbo.Order_No AS n
        WHERE n.order_no = @ReturnOrderNumber

        UPDATE d			--MR20201001
        SET d.SKU = (SELECT a.SKU FROM #ActivationOrderToReturn AS a WHERE a.Product_Type = 3)
        FROM dbo.orders AS d
        WHERE d.id = @ReturnOrderID

        ----------- updating spiff/promos tied to activation order to void if not invoiced yet -----------
        IF OBJECT_ID('tempdb..#TurnToVoid') IS NOT NULL
            BEGIN
                DROP TABLE #TurnToVoid;
            END;

        SELECT n.Order_No
        INTO #TurnToVoid
        FROM dbo.order_no AS n
        JOIN #OrdersTiedToTheActivation AS t
            ON t.AdditionalOrder_No = n.Order_No
        WHERE
            n.Paid = 0
            AND n.void = 0
            AND n.OrderType_ID NOT IN (59, 60, 70, 71) --GA20240423 Reverse Promo Instead of Void

        UPDATE n
        SET
            n.void = 1,
            n.DateFilled = @GetDate
        FROM dbo.order_no AS n
        JOIN #TurnToVoid AS t
            ON n.Order_No = t.Order_No
        JOIN dbo.orders AS d
            ON d.Order_No = n.Order_No
        WHERE ISNULL(d.ParentItemID, 0) = 0

        DELETE o
        FROM #OrdersTiedToTheActivation AS o
        JOIN #TurnToVoid AS t
            ON t.Order_No = o.AdditionalOrder_No

        ----------- Reverse the instant, retro, and additional spiff -----------
        IF OBJECT_ID('tempdb..#RetroAdditionalSpiff') IS NOT NULL
            BEGIN
                DROP TABLE #RetroAdditionalSpiff;
            END;

        SELECT
            o.Order_No,
            SUM(o.price) AS SummedRetroSpiff
        INTO #RetroAdditionalSpiff
        FROM #OrdersTiedToTheActivation AS o
        WHERE o.OrderType_ID IN (45, 46, 30, 34) --all retro and additional spiff
        GROUP BY o.Order_No

        INSERT INTO dbo.Orders
        (
            Order_No,
            Product_ID,
            Options,
            Addons,
            AddonMultP,
            AddonNonMultP,
            Price,
            Quantity,
            SKU,
            OptQuant,
            DiscAmount,
            Name,
            E911Tax,
            Fee,
            ParentItemID
        )
        SELECT
            @ReturnOrderNumber AS Order_No,
            a.Product_ID,
            N'' AS Options,
            N'' AS Addons,
            0.0 AS AddonMultP,
            0.0 AS AddonNonMultP,
            SUM(a.Price + ISNULL(o.SummedRetroSpiff, 0)) * -1 AS Price,
            1 AS Quantity,
            N'' AS SKU,
            0 AS OptQuant,
            0.00 AS DiscAmount,
            a.Name,
            0 AS E911Tax,
            0.00 AS Fee,
            @ReturnOrderID AS ReturnOrderID
        FROM #ActivationOrderToReturn AS a
        LEFT JOIN #RetroAdditionalSpiff AS o
            ON a.Order_No = o.Order_No
        WHERE a.Product_Type = 4
        GROUP BY
            a.Product_ID,
            a.Name

        ----------- remove orders we dont reverse -------
        DELETE o
        FROM #OrdersTiedToTheActivation AS o
        WHERE
            o.ordertype_ID NOT IN (25, 31, 32, 59, 60, 70, 71)
            AND o.PRODUCT_ID <> 9672 --GA20240423 Add Consumer Promos

        DECLARE
            @ProductID INT,
            @ReverseAmount DECIMAL(9, 2),
            @ReverseOrdertypeID INT,
            @ReverseAccountID INT,
            @ReverseAuthNumber INT,
            @REMOVEORDER INT

        DECLARE
            @RtnNewOrderID INT,
            @RtnNewOrderNumber INT;

        DECLARE CUR_REVERSE CURSOR FAST_FORWARD FOR
        SELECT
            Product_ID,
            OrderType_ID,
            Account_ID,
            Order_No,
            AdditionalOrder_No,
            -1 * Price AS ReverseAmount
        FROM #OrdersTiedToTheActivation

        OPEN CUR_REVERSE
        FETCH NEXT FROM CUR_REVERSE INTO
        @ProductID,
        @ReverseOrdertypeID,
        @ReverseAccountID,
        @ReverseAuthNumber,
        @REMOVEORDER,
        @ReverseAmount
        WHILE @@FETCH_STATUS = 0
            BEGIN
                EXEC OrderManagment.P_OrderManagment_Build_Full_Pending_Order
                    @AccountID = @ReverseAccountID,						-- int
                    @Datefrom = @GetDate,								-- datetime
                    @OrdertypeID = @ReverseOrdertypeID,					-- int
                    @OrderRefNumber = @ReturnOrderNumber,				-- int
                    @ProductID = @ProductID,							-- int
                    @Amount = @ReverseAmount,							-- decimal(9, 2)
                    @DiscountAmount = 0,								-- decimal(5, 2)
                    @NewOrderID = @RtnNewOrderID OUTPUT,			-- int
                    @NewOrderNumber = @RtnNewOrderNumber OUTPUT;	-- int

                DELETE FROM #OrdersTiedToTheActivation WHERE AdditionalOrder_No = @REMOVEORDER

                FETCH NEXT FROM CUR_REVERSE INTO
                @ProductID,
                @ReverseOrdertypeID,
                @ReverseAccountID,
                @ReverseAuthNumber,
                @REMOVEORDER,
                @ReverseAmount
            END
        CLOSE CUR_REVERSE
        DEALLOCATE CUR_REVERSE

        ----------- Reverse any commission -----------
        IF OBJECT_ID('tempdb..#Commissions') IS NOT NULL
            BEGIN
                DROP TABLE #Commissions;
            END;
        SELECT
            oc.Order_Commission_SK,
            oc.Order_No,
            oc.Orders_ID,
            oc.Account_ID,
            oc.Commission_Amt,
            oc.Datedue,
            oc.InvoiceNum
        INTO #Commissions
        FROM #ActivationOrderToReturn AS a
        JOIN dbo.Order_Commission AS oc
            ON oc.Orders_ID = a.ID

        INSERT INTO dbo.Order_Commission
        (
            Order_No,
            Orders_ID,
            Account_ID,
            Commission_Amt,
            Datedue
        )
        SELECT
            @ReturnOrderNumber AS Order_No,
            @ReturnOrderID AS Orders_ID,
            Account_ID AS Account_ID,
            (Commission_Amt) * -1 AS Commission_Amt,
            dbo.fnCalculateDueDate(Account_ID, @GetDate) AS DateDue
        FROM #Commissions

        ----------- Reverse Activation Fee -----------
        INSERT INTO dbo.Orders
        (
            Order_No,
            Product_ID,
            Options,
            Addons,
            AddonMultP,
            AddonNonMultP,
            Price,
            Quantity,
            SKU,
            OptQuant,
            DiscAmount,
            Name,
            E911Tax,
            Fee,
            ParentItemID
        )
        SELECT
            @ReturnOrderNumber AS Order_No,
            Product_ID,
            N'' AS Options,
            N'' AS Addons,
            0.0 AS AddonMultP,
            0.0 AS AddonNonMultP,
            Price * -1 AS Price,
            1 AS Quantity,
            N'' AS SKU,
            0 AS OptQuant,
            DiscAmount * -1 AS DiscAmount,
            [Name] AS [Name],
            0 AS E911Tax,
            0.00 AS Fee,
            @ReturnOrderID AS ParentItemID
        FROM #ActivationOrderToReturn WHERE Product_Type = 17

        UPDATE n
        SET
            n.OrderTotal =
            (
                SELECT ((a.Price - a.DiscAmount + a.Fee) * -1 + n.OrderTotal)
                FROM #ActivationOrderToReturn AS a
                WHERE a.Product_Type = 17
            )
        FROM dbo.Order_No AS n
        WHERE n.Order_No = @ReturnOrderNumber

        COMMIT TRANSACTION [Tran1]

        SELECT [on].*, oti.OrderType_Desc FROM dbo.Order_No AS [on]
        JOIN dbo.OrderType_ID AS oti ON [on].OrderType_ID = oti.OrderType_ID
        WHERE
            [on].AuthNumber IN (CAST(@ReturnOrderNumber AS VARCHAR(20)), CAST(@ActivationOrder AS VARCHAR(20)))
            OR [on].Order_No IN (@ReturnOrderNumber, @ActivationOrder)

    END TRY
    BEGIN CATCH
        ROLLBACK TRANSACTION [Tran1]

        SELECT
            @ErrorMessage = ERROR_MESSAGE(),
            @ErrorSeverity = ERROR_SEVERITY(),
            @ErrorState = ERROR_STATE();

        RAISERROR (@ErrorMessage, @ErrorSeverity, @ErrorState)
    END CATCH
END
